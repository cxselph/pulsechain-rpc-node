#!/usr/bin/env python3
"""node-control: does what the control page asks, from a fixed list of actions.

The control page (a container with no Docker access) drops small JSON request
files into the requests directory. A systemd path unit starts this script as the
repo owner, which:

  process   handles each request: restart-node, restart-geth, restart-beacon,
            check-updates, apply-update, rollback. Anything else is rejected.
  refresh   writes status.json (git/update state, containers, Debian updates)
            for the page to read. Also run by a timer.

"apply-update" only fast-forwards to what is already merged on origin/main,
then runs the repo's own scripts (pinned images only). Standard library only.
"""
import datetime as dt
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get("NODE_CONTROL_REPO", os.path.dirname(HERE))
STATE_DIR = os.environ.get("NODE_CONTROL_STATE", "/var/lib/node-control/state")
REQ_DIR = os.environ.get("NODE_CONTROL_REQUESTS", "/var/lib/node-control/requests")
BRANCH = "main"
REMOTE = "origin"
CONTAINERS = [
    "pulse-geth", "pulse-beacon", "pulse-caddy", "pulse-control",
    "pulse-grafana", "pulse-prometheus", "pulse-node-exporter",
]
MAX_REQUEST_BYTES = 4096
KEEP_LOGS = 30
KEEP_HISTORY = 200

ACTIONS = {
    "restart-node": "Restart the node (go-pulse + Prysm)",
    "restart-geth": "Restart go-pulse",
    "restart-beacon": "Restart Prysm",
    "check-updates": "Check for updates",
    "apply-update": "Apply update",
    "rollback": "Roll back the last update",
}


# --- helpers ---------------------------------------------------------------

def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def run(cmd, timeout=120, cwd=None):
    """Run a command, return (returncode, combined output)."""
    env = dict(os.environ)
    env["PATH"] = env.get("PATH", "/usr/bin:/bin") + ":/usr/sbin:/sbin"
    try:
        p = subprocess.run(
            cmd, cwd=cwd or REPO, env=env, timeout=timeout,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout or ""
        if isinstance(out, bytes):
            out = out.decode(errors="replace")
        return 124, out + f"\n[timed out after {timeout}s]"
    except FileNotFoundError as exc:
        return 127, str(exc)


def git(*args, timeout=60):
    return run(["git", *args], timeout=timeout)


def git_out(*args):
    rc, out = git(*args)
    return out.strip() if rc == 0 else ""


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp.")
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def read_json(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def state(name):
    return os.path.join(STATE_DIR, name)


class Lock:
    """One node-control run at a time (process and refresh share the repo)."""

    def __enter__(self):
        os.makedirs(STATE_DIR, exist_ok=True)
        self.fh = open(state(".lock"), "w")
        fcntl.flock(self.fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()


# --- status ---------------------------------------------------------------

PIN_RE = re.compile(r'^(GETH|BEACON)_IMAGE_PINNED="([^"]+)"', re.M)


def pins(common_sh_text):
    found = {k.lower(): v for k, v in PIN_RE.findall(common_sh_text or "")}
    # registry/path:tag@sha256:... -> tag
    return {k: v.split("@")[0].rsplit(":", 1)[-1] for k, v in found.items()}


def classify(paths):
    """Which parts of the install a set of changed paths touches."""
    areas = {"node": False, "monitoring": False, "proxy": False, "control": False, "tailscale": False}
    manual = []
    for p in paths:
        if p in ("docker-compose.yml", "common.sh"):
            areas["node"] = True
        elif p.startswith("monitoring/exporter/") or p == "monitoring/install.sh":
            manual.append("./monitoring/install.sh")
        elif p.startswith("monitoring/"):
            areas["monitoring"] = True
        elif p.startswith("proxy/"):
            areas["proxy"] = True
        elif p == "tailscale/install.sh":
            manual.append("./tailscale/install.sh")
        elif p.startswith("tailscale/"):
            areas["tailscale"] = True
        elif p.startswith("control/systemd/") or p == "control/install.sh":
            manual.append("./control/install.sh")
        elif p.startswith("control/") and p != "control/node-control.py":
            areas["control"] = True
    return areas, sorted(set(manual))


def repo_status(fetch):
    info = {"path": REPO}
    if fetch:
        rc, out = git("fetch", "--quiet", REMOTE, BRANCH, timeout=90)
        info["fetch_ok"] = rc == 0
        if rc == 0:
            info["last_fetch"] = now()
        else:
            info["fetch_error"] = out.strip()[-300:]
    previous = read_json(state("status.json"), {}) or {}
    if "last_fetch" not in info:
        info["last_fetch"] = previous.get("repo", {}).get("last_fetch")
    info["branch"] = git_out("rev-parse", "--abbrev-ref", "HEAD")
    info["head"] = git_out("rev-parse", "HEAD")
    info["head_short"] = info["head"][:7]
    info["head_subject"] = git_out("log", "-1", "--format=%s")
    info["head_date"] = git_out("log", "-1", "--format=%cs")
    info["dirty"] = bool(git_out("status", "--porcelain", "--untracked-files=no"))
    upstream = f"{REMOTE}/{BRANCH}"
    info["upstream"] = git_out("rev-parse", upstream)
    behind = git_out("rev-list", "--count", f"HEAD..{upstream}")
    ahead = git_out("rev-list", "--count", f"{upstream}..HEAD")
    info["behind"] = int(behind) if behind.isdigit() else 0
    info["ahead"] = int(ahead) if ahead.isdigit() else 0
    info["incoming"] = []
    for line in git_out("log", "--format=%h%x09%cs%x09%s", "-n", "20", f"HEAD..{upstream}").splitlines():
        sha, date, subject = (line.split("\t", 2) + ["", ""])[:3]
        info["incoming"].append({"sha": sha, "date": date, "subject": subject})
    info["pins"] = pins(git_out("show", "HEAD:common.sh"))
    info["incoming_pins"] = pins(git_out("show", f"{upstream}:common.sh")) if info["behind"] else {}
    changed = git_out("diff", "--name-only", "HEAD", upstream).splitlines() if info["behind"] else []
    areas, manual = classify(changed)
    info["incoming_areas"] = [k for k, v in areas.items() if v]
    info["incoming_manual"] = manual
    reasons = []
    if info["branch"] != BRANCH:
        reasons.append(f"checkout is on '{info['branch']}', not {BRANCH}")
    if info["dirty"]:
        reasons.append("the checkout has local changes")
    if info["ahead"]:
        reasons.append(f"the checkout has {info['ahead']} commit(s) not on {upstream}")
    info["can_apply"] = info["behind"] > 0 and not reasons
    info["blocked_reasons"] = reasons
    prev = (read_json(state("rollback.json"), {}) or {}).get("from")
    info["rollback_to"] = None
    if prev and prev != info["head"] and git("merge-base", "--is-ancestor", prev, "HEAD")[0] == 0:
        info["rollback_to"] = prev[:7]
    return info


def container_status():
    rc, out = run(["docker", "inspect", *CONTAINERS], timeout=30)
    result = {}
    try:
        items = json.loads(out) if out.strip().startswith("[") else []
    except ValueError:
        items = []
    for item in items:
        name = item.get("Name", "").lstrip("/")
        st = item.get("State", {})
        result[name] = {
            "status": st.get("Status"),
            "running": st.get("Running", False),
            "started_at": st.get("StartedAt"),
            "health": (st.get("Health") or {}).get("Status"),
            "restart_count": item.get("RestartCount", 0),
            "image": item.get("Config", {}).get("Image", ""),
        }
    for name in CONTAINERS:
        result.setdefault(name, {"status": "not installed", "running": False})
    return result


def system_status():
    info = {"reboot_required": os.path.exists("/var/run/reboot-required")}
    rc, out = run(["apt-get", "-s", "-o", "Debug::NoLocking=1", "upgrade"], timeout=60)
    if rc == 0:
        inst = [l for l in out.splitlines() if l.startswith("Inst ")]
        info["apt_upgradable"] = len(inst)
        info["apt_security"] = sum(1 for l in inst if "security" in l.lower())
    try:
        with open("/proc/uptime") as fh:
            info["uptime_seconds"] = int(float(fh.read().split()[0]))
    except OSError:
        pass
    return info


def refresh(fetch=True):
    status = {
        "generated_at": now(),
        "repo": repo_status(fetch),
        "containers": container_status(),
        "system": system_status(),
    }
    write_json(state("status.json"), status)
    return status


# --- actions ----------------------------------------------------------------

def compose(*args, timeout=900):
    return run(["docker", "compose", *args], timeout=timeout)


def followups(changed_paths, log):
    """After the checkout moved: restart what the change touched."""
    areas, manual = classify(changed_paths)
    done = []
    ok = True
    if areas["node"]:
        rc, out = run(["./update.sh"], timeout=1800)
        log.append("$ ./update.sh\n" + out)
        ok &= rc == 0
        done.append("node containers updated" if rc == 0 else "node update FAILED")
    if areas["monitoring"] and os.path.exists(os.path.join(REPO, "monitoring/.env")):
        rc, out = run(["bash", "-c", "source monitoring/lib.sh && mon_compose pull -q && ./monitoring/restart.sh"], timeout=900)
        log.append("$ monitoring pull + restart\n" + out)
        ok &= rc == 0
        done.append("monitoring restarted" if rc == 0 else "monitoring restart FAILED")
    if areas["proxy"] and os.path.exists(os.path.join(REPO, "proxy/.env")):
        rc, out = run(["bash", "-c", "source proxy/lib.sh && proxy_compose pull -q && ./proxy/restart.sh"], timeout=600)
        log.append("$ proxy pull + restart\n" + out)
        ok &= rc == 0
        done.append("HTTPS front end restarted" if rc == 0 else "HTTPS front end restart FAILED")
    if areas["tailscale"] and os.path.exists(os.path.join(REPO, "tailscale/.env")):
        rc, out = run(["bash", "-c", "source tailscale/lib.sh && ts_compose pull -q && ./tailscale/restart.sh"], timeout=300)
        log.append("$ tailscale DNS pull + restart\n" + out)
        ok &= rc == 0
        done.append("Tailscale DNS answer restarted" if rc == 0 else "Tailscale DNS restart FAILED")
    if areas["control"] and os.path.exists(os.path.join(REPO, "control/.env")):
        # Last: this restarts the control page itself.
        rc, out = run(["./control/restart.sh"], timeout=900)
        log.append("$ ./control/restart.sh\n" + out)
        ok &= rc == 0
        done.append("control page rebuilt" if rc == 0 else "control page rebuild FAILED")
    if manual:
        done.append("needs a manual step over SSH: " + ", ".join(manual))
    if not done:
        done.append("nothing needed restarting")
    return ok, done


def act_restart(services):
    def action(log):
        rc, out = compose("restart", *services)
        log.append(f"$ docker compose restart {' '.join(services)}\n" + out)
        what = " + ".join(services) if services else "go-pulse + Prysm"
        return rc == 0, (f"restarted {what}" if rc == 0 else f"restart of {what} FAILED")
    return action


def act_check_updates(log):
    info = refresh(fetch=True)["repo"]
    if not info.get("fetch_ok"):
        log.append(info.get("fetch_error", ""))
        return False, "could not reach GitHub to check for updates"
    if info["behind"]:
        return True, f"{info['behind']} update(s) available"
    return True, "up to date"


def act_apply_update(log):
    info = repo_status(fetch=True)
    if not info.get("fetch_ok"):
        return False, "could not reach GitHub: " + info.get("fetch_error", "")[:120]
    if not info["behind"]:
        return True, "already up to date"
    if not info["can_apply"]:
        return False, "not applied: " + "; ".join(info["blocked_reasons"])
    before = info["head"]
    rc, out = git("merge", "--ff-only", f"{REMOTE}/{BRANCH}")
    log.append(f"$ git merge --ff-only {REMOTE}/{BRANCH}\n" + out)
    if rc != 0:
        return False, "fast-forward failed (nothing changed)"
    after = git_out("rev-parse", "HEAD")
    write_json(state("rollback.json"), {"from": before, "to": after, "at": now()})
    changed = git_out("diff", "--name-only", before, after).splitlines()
    ok, done = followups(changed, log)
    return ok, f"updated {before[:7]} → {after[:7]}: " + "; ".join(done)


def act_rollback(log):
    rb = read_json(state("rollback.json"), {}) or {}
    target, head = rb.get("from"), git_out("rev-parse", "HEAD")
    if not target:
        return False, "nothing to roll back to"
    if target == head or git("merge-base", "--is-ancestor", target, "HEAD")[0] != 0:
        return False, "the recorded rollback point no longer applies"
    if git_out("status", "--porcelain", "--untracked-files=no"):
        return False, "not rolled back: the checkout has local changes"
    rc, out = git("reset", "--hard", target)
    log.append(f"$ git reset --hard {target[:7]}\n" + out)
    if rc != 0:
        return False, "rollback failed (git reset)"
    changed = git_out("diff", "--name-only", target, head).splitlines()
    ok, done = followups(changed, log)
    os.remove(state("rollback.json"))
    return ok, f"rolled back {head[:7]} → {target[:7]}: " + "; ".join(done)


HANDLERS = {
    "restart-node": act_restart([]),
    "restart-geth": act_restart(["geth"]),
    "restart-beacon": act_restart(["beacon"]),
    "check-updates": act_check_updates,
    "apply-update": act_apply_update,
    "rollback": act_rollback,
}
assert set(HANDLERS) == set(ACTIONS)


# --- request processing -------------------------------------------------------

ID_RE = re.compile(r"^[0-9a-f]{16,32}$")


def read_request(path):
    """Claim (delete) a request file and return a validated dict, or None."""
    try:
        if os.path.getsize(path) > MAX_REQUEST_BYTES:
            os.remove(path)
            return {"action": None, "error": "request too large"}
        with open(path) as fh:
            raw = fh.read(MAX_REQUEST_BYTES)
        os.remove(path)
    except OSError:
        return None
    try:
        req = json.loads(raw)
        if not isinstance(req, dict):
            raise ValueError
    except ValueError:
        return {"action": None, "error": "not valid JSON"}
    action = req.get("action")
    rid = str(req.get("id", ""))
    by = re.sub(r"[^A-Za-z0-9 ._:@()-]", "", str(req.get("by", "")))[:64] or "unknown"
    if not ID_RE.match(rid):
        rid = uuid.uuid4().hex[:16]
    if action not in ACTIONS:
        return {"id": rid, "action": None, "by": by, "error": f"unknown action {str(action)[:40]!r}"}
    return {"id": rid, "action": action, "by": by}


def record(entry, log_lines):
    os.makedirs(state("logs"), exist_ok=True)
    log_path = state(os.path.join("logs", f"{entry['id']}.log"))
    with open(log_path, "w") as fh:
        fh.write("\n".join(log_lines))
    os.chmod(log_path, 0o644)
    logs = sorted((os.path.join(state("logs"), f) for f in os.listdir(state("logs"))), key=os.path.getmtime)
    for old in logs[:-KEEP_LOGS]:
        os.remove(old)
    hist = state("history.jsonl")
    lines = []
    if os.path.exists(hist):
        with open(hist) as fh:
            lines = fh.read().splitlines()[-(KEEP_HISTORY - 1):]
    lines.append(json.dumps(entry))
    fd, tmp = tempfile.mkstemp(dir=STATE_DIR, prefix=".tmp.")
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, hist)


def process():
    handled = 0
    while True:
        try:
            files = sorted(
                (os.path.join(REQ_DIR, f) for f in os.listdir(REQ_DIR) if f.endswith(".json")),
                key=os.path.getmtime,
            )
        except FileNotFoundError:
            files = []
        if not files:
            break
        for path in files:
            req = read_request(path)
            if req is None:
                continue
            entry = {"id": req.get("id") or uuid.uuid4().hex[:16], "action": req.get("action"),
                     "label": ACTIONS.get(req.get("action"), "rejected request"),
                     "by": req.get("by", "unknown"), "started": now()}
            log = []
            if req.get("action") is None:
                entry.update(ok=False, summary="rejected: " + req.get("error", "invalid request"))
            else:
                write_json(state("running.json"), entry)
                try:
                    ok, summary = HANDLERS[req["action"]](log)
                except Exception as exc:  # noqa: BLE001 - always record the outcome
                    ok, summary = False, f"failed: {exc}"
                entry.update(ok=bool(ok), summary=summary)
            entry["finished"] = now()
            record(entry, log)
            try:
                os.remove(state("running.json"))
            except FileNotFoundError:
                pass
            handled += 1
        refresh(fetch=False)
    return handled


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    with Lock():
        if cmd == "process":
            process()
        elif cmd == "refresh":
            refresh(fetch=True)
        else:
            print(__doc__)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
