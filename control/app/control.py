"""Control page for a pulsechain-rpc-node host.

Shows node health and offers a fixed set of actions. It has no Docker access
and no write access to the repo: an action becomes a small JSON request file
that node-control (a systemd service on the host) carries out.
"""
import base64
import collections
import hmac
import json
import os
import re
import secrets
import threading
import time
import urllib.request
import uuid
from datetime import datetime, timezone

from flask import Flask, abort, jsonify, redirect, render_template, request, send_from_directory, session, url_for
from werkzeug.middleware.proxy_fix import ProxyFix
from werkzeug.security import check_password_hash

# Served at the site root and before sign-in: Safari fetches these without the session.
HOME_SCREEN_FILES = {
    "apple-touch-icon.png": "image/png",
    "icon-512.png": "image/png",
    "manifest.webmanifest": "application/manifest+json",
}

STATE_DIR = os.environ.get("CONTROL_STATE_DIR", "/state")
REQ_DIR = os.environ.get("CONTROL_REQUESTS_DIR", "/requests")
CHAIN_FS = os.environ.get("CONTROL_CHAIN_FS", "/chainfs")
RPC_URL = os.environ.get("CONTROL_RPC_URL", "http://127.0.0.1:8545")
BEACON_URL = os.environ.get("CONTROL_BEACON_URL", "http://127.0.0.1:3500")
PROM_URL = os.environ.get("CONTROL_PROMETHEUS_URL", "http://127.0.0.1:9090")
PUBLIC_HOSTNAME = os.environ.get("PUBLIC_HOSTNAME", "")

# Same list node-control accepts. Descriptions are shown on the confirm screen.
ACTIONS = {
    "restart-node": ("Restart the node",
                     "Restarts go-pulse and Prysm. Wallets lose the connection for a minute or two; "
                     "go-pulse may take up to 5 minutes to shut down cleanly."),
    "restart-geth": ("Restart go-pulse", "Restarts only the execution client (go-pulse)."),
    "restart-beacon": ("Restart Prysm", "Restarts only the beacon client (Prysm)."),
    "check-updates": ("Check for updates", "Fetches the fork's main branch from GitHub. Changes nothing."),
    "apply-update": ("Apply update",
                     "Fast-forwards to what is merged on GitHub main, then restarts only what the "
                     "update touches (pinned images only)."),
    "rollback": ("Roll back", "Returns to the version before the last update and restarts what it touches."),
}

# Wallet network settings shown on the page (PulseChain mainnet).
CHAIN = {"name": "PulseChain", "chain_id": 369, "symbol": "PLS", "decimals": 18,
         "explorer": "https://scan.pulsechain.com"}

# Validator readiness, from the Prometheus recording rules in monitoring/.
READINESS_QUERIES = {
    "ready": "pulse:ready",
    "synced": "pulse:synced",
    "peers_ok": "pulse:peers_ok",
    "clock_ok": "pulse:clock_ok",
    "streak_days": "(time() - max_over_time(pulse:not_ready_at[45d])) / 86400 or count_over_time(pulse:ready[45d]) / 1440",
    "uptime_pct": "avg_over_time(pulse:both_up[30d]) * 100",
    "downtime_min": "round((1 - avg_over_time(pulse:both_up[30d])) * count_over_time(pulse:both_up[30d]))",
    "outages": "ceil(changes(pulse:both_up[30d]) / 2)",
    "history_days": "count_over_time(pulse:ready[30d]) / 1440",
    "inbound_avg": "avg_over_time(pulse:inbound_peers[30d])",
}

# Console: containers whose recent logs node-logs keeps in STATE_DIR/live.
CONSOLE_LOGS = {"geth": ("go-pulse", "pulse-geth"), "beacon": ("Prysm", "pulse-beacon")}

LOGIN_WINDOW = 15 * 60
LOGIN_MAX_PER_IP = 5
LOGIN_MAX_TOTAL = 20


def _decode_hash(value):
    # Stored base64-encoded in .env so Compose never sees the "$" in werkzeug hashes.
    if not value:
        return ""
    try:
        return base64.b64decode(value.encode(), validate=True).decode()
    except ValueError:
        return ""


def create_app(config=None):
    app = Flask(__name__)
    app.config.update(
        SECRET_KEY=os.environ.get("CONTROL_SECRET_KEY") or secrets.token_hex(32),
        PASSWORD_HASH=_decode_hash(os.environ.get("CONTROL_PASSWORD_HASH", "")),
        SESSION_COOKIE_NAME="__Host-control",
        SESSION_COOKIE_SECURE=True,
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Strict",
        PERMANENT_SESSION_LIFETIME=30 * 24 * 3600,
        MAX_CONTENT_LENGTH=16 * 1024,
        TRUSTED_HOSTS=[h for h in (PUBLIC_HOSTNAME, "127.0.0.1", "localhost") if h],
    )
    if config:
        app.config.update(config)
    app.add_template_filter(fmt_bytes, "bytes")
    app.add_template_filter(fmt_num, "num")
    app.add_template_filter(fmt_ago, "ago")
    # Caddy on 127.0.0.1 is the only client; trust its one X-Forwarded-For hop.
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

    failures = collections.defaultdict(collections.deque)
    failures_lock = threading.Lock()

    def too_many_failures(ip):
        cutoff = time.time() - LOGIN_WINDOW
        with failures_lock:
            for q in list(failures.values()):
                while q and q[0] < cutoff:
                    q.popleft()
            total = sum(len(q) for q in failures.values())
            return len(failures[ip]) >= LOGIN_MAX_PER_IP or total >= LOGIN_MAX_TOTAL

    def note_failure(ip):
        with failures_lock:
            failures[ip].append(time.time())

    # --- request guards --------------------------------------------------
    @app.before_request
    def guards():
        # Untrusted Host or unknown path: let Flask answer with its 400/404.
        if request.routing_exception is not None or request.endpoint in ("healthz", "static", "home_screen_file"):
            return None
        if request.method == "POST":
            token = session.get("csrf")
            sent = request.form.get("csrf", "")
            if not token or not hmac.compare_digest(token, sent):
                abort(400, "Your session expired. Go back, reload the page and try again.")
        if request.endpoint not in ("login",) and not session.get("auth"):
            # Data endpoints answer 401 (scripts send you to sign in); pages redirect.
            if request.endpoint in ("api_status", "console_lines") or request.path.startswith("/fragment/"):
                abort(401)
            return redirect(url_for("login"))
        return None

    @app.after_request
    def headers(resp):
        resp.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
            "connect-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'"
        )
        resp.headers["X-Frame-Options"] = "DENY"
        resp.headers["X-Content-Type-Options"] = "nosniff"
        resp.headers["Referrer-Policy"] = "no-referrer"
        if request.endpoint not in ("static", "home_screen_file"):
            resp.headers["Cache-Control"] = "no-store"
        return resp

    @app.context_processor
    def inject():
        if "csrf" not in session:
            session["csrf"] = secrets.token_urlsafe(32)
        return {"csrf": session["csrf"], "hostname": PUBLIC_HOSTNAME or request.host, "ACTIONS": ACTIONS, "CHAIN": CHAIN}

    # --- routes ------------------------------------------------------------
    @app.get("/healthz")
    def healthz():
        return {"ok": True}

    @app.get("/<any(" + ", ".join(f'"{n}"' for n in HOME_SCREEN_FILES) + "):name>")
    def home_screen_file(name):
        return send_from_directory(app.static_folder, name, mimetype=HOME_SCREEN_FILES[name], max_age=86400)

    @app.route("/login", methods=["GET", "POST"])
    def login():
        error = None
        if request.method == "POST":
            ip = request.remote_addr or "?"
            if too_many_failures(ip):
                return render_template("login.html", error="Too many attempts. Wait 15 minutes and try again."), 429
            pw_hash = app.config["PASSWORD_HASH"]
            password = request.form.get("password", "")
            if pw_hash and password and check_password_hash(pw_hash, password):
                session.clear()
                session.permanent = True
                session["auth"] = True
                session["csrf"] = secrets.token_urlsafe(32)
                return redirect(url_for("index"))
            note_failure(ip)
            error = "Wrong password." if pw_hash else "No password is set yet. Run ./control/set-password.sh on the node."
        return render_template("login.html", error=error), (401 if error else 200)

    @app.post("/logout")
    def logout():
        session.clear()
        return redirect(url_for("login"))

    @app.get("/")
    def index():
        return render_template("dashboard.html", s=collect_status(), message=session.pop("message", None))

    @app.get("/fragment/status")
    def fragment_status():
        return render_template("_status.html", s=collect_status())

    @app.get("/api/status")
    def api_status():
        return jsonify(collect_status())

    @app.post("/action/<name>")
    def action(name):
        if name not in ACTIONS:
            abort(404)
        s = collect_status()
        if request.form.get("confirmed") != "yes":
            return render_template("confirm.html", name=name, s=s)
        problem = action_blocked(name, s)
        if problem:
            session["message"] = ("error", problem)
            return redirect(url_for("index"))
        submit_request(name, request.remote_addr or "?")
        session["message"] = ("ok", f"{ACTIONS[name][0]}: started. This page updates as it runs.")
        return redirect(url_for("index"))

    @app.get("/console")
    def console():
        return render_template("console.html", logs=CONSOLE_LOGS)

    @app.get("/console/<name>.json")
    def console_lines(name):
        if name not in CONSOLE_LOGS:
            abort(404)
        try:
            after = int(request.args.get("after", "0"))
        except ValueError:
            after = 0
        return jsonify(read_live_log(CONSOLE_LOGS[name][1], after))

    @app.get("/log/<rid>")
    def log(rid):
        if not re.fullmatch(r"[0-9a-f]{16,32}", rid):
            abort(404)
        path = os.path.join(STATE_DIR, "logs", f"{rid}.log")
        try:
            with open(path) as fh:
                text = fh.read()[-20000:]
        except OSError:
            abort(404)
        entry = next((e for e in read_history(200) if e.get("id") == rid), {})
        return render_template("log.html", text=text, entry=entry)

    return app


# --- status --------------------------------------------------------------------

_cache = {"at": 0.0, "data": None}
_cache_lock = threading.Lock()
_readiness_cache = {"at": 0.0, "data": None}


def prom_scalar(expr):
    """First value of an instant query, or None (no data / Prometheus not installed)."""
    q = urllib.request.quote(expr)
    res = _get_json(f"{PROM_URL}/api/v1/query?query={q}")["data"]["result"]
    return float(res[0]["value"][1]) if res else None


def readiness():
    """Validator readiness numbers; None when monitoring isn't installed. Cached 60 s."""
    if _readiness_cache["data"] is not None and time.time() - _readiness_cache["at"] < 60:
        return _readiness_cache["data"] or None
    data = {}
    try:
        for key, expr in READINESS_QUERIES.items():
            data[key] = prom_scalar(expr)
    except Exception:  # noqa: BLE001 - Prometheus not installed or not answering
        data = {}
    if data and data.get("ready") is None:
        data = {}  # recording rules not loaded yet
    _readiness_cache.update(at=time.time(), data=data)
    return data or None


def _post_json(url, method):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": []}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=3) as r:
        return json.load(r)["result"]


def _get_json(url):
    with urllib.request.urlopen(url, timeout=3) as r:
        return json.load(r)


def _num(v):
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, int):
        return v
    if isinstance(v, str):
        return int(v, 16) if v.startswith("0x") else int(v)
    return 0


def read_json(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def read_history(n=10):
    try:
        with open(os.path.join(STATE_DIR, "history.jsonl")) as fh:
            lines = fh.read().splitlines()[-n:]
    except OSError:
        return []
    out = []
    for line in reversed(lines):
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def read_live_log(container, after=0):
    """Lines newer than `after` from node-logs' file for a container."""
    path = os.path.join(STATE_DIR, "live", f"{container}.log")
    try:
        with open(path) as fh:
            head = fh.readline()
            lines = fh.read().splitlines()
        updated = os.path.getmtime(path)
    except OSError:
        return {"seq": 0, "lines": [], "missing": True}
    m = re.match(r"#seq (\d+)", head)
    seq = int(m.group(1)) if m else len(lines)
    first = seq - len(lines) + 1
    if after < first - 1 or after > seq:  # gap, or the helper restarted: send everything
        new = lines
        reset = True
    else:
        new = lines[after - first + 1:] if after >= first else lines
        reset = False
    return {"seq": seq, "lines": new, "reset": reset, "age": max(0, int(time.time() - updated))}


def pending_requests():
    try:
        return [f for f in os.listdir(REQ_DIR) if f.endswith(".json")]
    except OSError:
        return []


def collect_status():
    with _cache_lock:
        if _cache["data"] and time.time() - _cache["at"] < 3:
            return _cache["data"]
    s = {"now": datetime.now(timezone.utc).isoformat(timespec="seconds")}

    el = {"up": False}
    try:
        syncing = _post_json(RPC_URL, "eth_syncing")
        el["peers"] = _num(_post_json(RPC_URL, "net_peerCount"))
        if syncing is False:
            el["syncing"] = False
            el["current"] = el["highest"] = _num(_post_json(RPC_URL, "eth_blockNumber"))
        else:
            el["syncing"] = True
            el["current"] = _num(syncing.get("currentBlock", 0))
            el["highest"] = _num(syncing.get("highestBlock", 0))
            el["accounts"] = _num(syncing.get("syncedAccounts", 0))
            el["healed"] = _num(syncing.get("healedTrienodes", 0))
            el["healing_pending"] = _num(syncing.get("healingTrienodes", 0))
        el["up"] = True
    except Exception:  # noqa: BLE001
        pass
    if el.get("highest"):
        el["percent"] = min(100.0, 100.0 * el["current"] / el["highest"])
    el["phase"] = sync_phase(el)
    s["el"] = el

    cl = {"up": False}
    try:
        d = _get_json(BEACON_URL + "/eth/v1/node/syncing")["data"]
        cl.update(up=True, syncing=bool(d.get("is_syncing")), el_offline=bool(d.get("el_offline")),
                  head_slot=_num(d.get("head_slot", 0)), distance=_num(d.get("sync_distance", 0)))
        cl["peers"] = _num(_get_json(BEACON_URL + "/eth/v1/node/peer_count")["data"].get("connected", 0))
    except Exception:  # noqa: BLE001
        pass
    s["cl"] = cl

    # Healing progress (trie nodes per minute) while in the final state phase.
    if el.get("phase") == "state":
        try:
            heal = prom_scalar("rate(pulse_el_snap_healed_trienodes[10m]) * 60")
            if heal is not None:
                s["heal_per_min"] = heal
        except Exception:  # noqa: BLE001
            pass

    # Blocks per second over 30 min, from Prometheus (if monitoring is installed).
    try:
        q = urllib.request.quote("rate(pulse_el_current_block[30m])")
        res = _get_json(f"{PROM_URL}/api/v1/query?query={q}")["data"]["result"]
        rate = float(res[0]["value"][1]) if res else 0.0
        s["blocks_per_min"] = rate * 60
        if el.get("syncing") and rate > 0 and el.get("highest", 0) > el.get("current", 0):
            s["eta_hours"] = (el["highest"] - el["current"]) / rate / 3600
    except Exception:  # noqa: BLE001
        pass

    try:
        st = os.statvfs(CHAIN_FS)
        total, free = st.f_blocks * st.f_frsize, st.f_bavail * st.f_frsize
        s["disk"] = {"total": total, "free": free, "used_pct": 100.0 * (total - free) / total if total else 0}
    except OSError:
        s["disk"] = None

    helper = read_json(os.path.join(STATE_DIR, "status.json"))
    s["helper"] = helper
    s["running"] = read_json(os.path.join(STATE_DIR, "running.json"))
    s["queued"] = len(pending_requests())
    s["history"] = read_history(8)
    s["readiness"] = readiness()
    s["health"] = health(s)
    with _cache_lock:
        _cache.update(at=time.time(), data=s)
    return s


def sync_phase(el):
    """Where go-pulse is in its sync, in words the page can use.

    synced    eth_syncing is false
    starting  no target yet (waiting for the beacon node / downloading headers)
    blocks    downloading blocks (current < highest)
    state     all blocks in, finishing the state download and healing (final step);
              current can briefly read above highest here, which is normal
    """
    if not el.get("up"):
        return "down"
    if not el.get("syncing"):
        return "synced"
    if not el.get("highest"):
        return "starting"
    if el.get("current", 0) < el["highest"]:
        return "blocks"
    return "state"


PHASE_TEXT = {
    "starting": "syncing (waiting for the chain head)",
    "state": "syncing (blocks done, healing state: final step)",
}


def health(s):
    """(level, headline) for the banner: green / yellow / red."""
    el, cl, disk, helper = s["el"], s["cl"], s.get("disk"), s.get("helper") or {}
    problems, warnings = [], []
    if not el.get("up"):
        problems.append("go-pulse is not answering")
    if not cl.get("up"):
        problems.append("Prysm is not answering")
    containers = helper.get("containers", {})
    for name in ("pulse-geth", "pulse-beacon"):
        c = containers.get(name)
        if c and not c.get("running"):
            problems.append(f"{name} is {c.get('status')}")
    if disk and disk["used_pct"] >= 90:
        problems.append(f"chain disk {disk['used_pct']:.0f}% full")
    if el.get("up") and el.get("syncing"):
        phase = el.get("phase") or sync_phase(el)
        warnings.append(PHASE_TEXT.get(phase, f"syncing ({el.get('percent', 0):.1f}% of blocks)"))
    if el.get("up") and el.get("peers", 0) < 5:
        warnings.append("few go-pulse peers")
    if cl.get("up") and cl.get("peers", 0) < 5:
        warnings.append("few Prysm peers")
    if cl.get("up") and cl.get("el_offline") and el.get("up") and not el.get("syncing"):
        warnings.append("Prysm reports go-pulse offline")
    if disk and 85 <= disk["used_pct"] < 90:
        warnings.append(f"chain disk {disk['used_pct']:.0f}% full")
    if helper.get("repo", {}).get("behind"):
        warnings.append("update available")
    if not helper:
        warnings.append("node-control helper not reporting")
    if problems:
        return ("red", "; ".join(problems))
    if warnings:
        return ("yellow", "; ".join(warnings))
    return ("green", "Synced and healthy")


def action_blocked(name, s):
    if s.get("running") or s.get("queued"):
        return "Another action is still running. Wait for it to finish."
    if not s.get("helper"):
        return "The node-control helper isn't reporting, so nothing would carry this out. Check ./control/status.sh."
    repo = s["helper"].get("repo", {})
    if name == "apply-update":
        if not repo.get("behind"):
            return "Already up to date. Use Check for updates first."
        if not repo.get("can_apply"):
            return "Can't apply: " + "; ".join(repo.get("blocked_reasons") or ["unknown reason"])
    if name == "rollback" and not repo.get("rollback_to"):
        return "There is no update to roll back."
    return None


def submit_request(name, ip):
    rid = uuid.uuid4().hex[:16]
    req = {"id": rid, "action": name, "by": f"web ({ip})",
           "requested_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}
    tmp = os.path.join(REQ_DIR, f".{rid}.tmp")
    final = os.path.join(REQ_DIR, f"{int(time.time())}-{rid}.json")
    old = os.umask(0o007)
    try:
        with open(tmp, "w") as fh:
            json.dump(req, fh)
    finally:
        os.umask(old)
    os.replace(tmp, final)
    with _cache_lock:
        _cache["data"] = None
    return rid


def fmt_bytes(n):
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit in ("GB", "TB") else f"{n:.0f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def fmt_num(n):
    try:
        return f"{int(n):,}"
    except (TypeError, ValueError):
        return "—"


def fmt_ago(iso):
    if not iso:
        return "—"
    try:
        t = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return iso
    secs = int((datetime.now(timezone.utc) - t).total_seconds())
    if secs < 0 or t.year < 2000:
        return "—"
    for size, unit in ((86400, "d"), (3600, "h"), (60, "min")):
        if secs >= size:
            return f"{secs // size} {unit} ago"
    return f"{secs} s ago"


app = create_app()
