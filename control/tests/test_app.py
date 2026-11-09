"""Control page web app: auth, CSRF, rate limit, actions -> request files."""
import json
import os
import re
import stat
import sys
import tempfile
import time
import unittest
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "app"))

import control  # noqa: E402
from werkzeug.security import generate_password_hash  # noqa: E402

PASSWORD = "correct horse battery staple"
BASE = "https://rpc.home"


def fake_status(**over):
    s = {
        "now": "2026-10-17T20:00:00+00:00",
        "el": {"up": True, "syncing": True, "current": 100, "highest": 200, "peers": 30, "percent": 50.0, "phase": "blocks"},
        "cl": {"up": True, "syncing": False, "el_offline": True, "head_slot": 7, "distance": 0, "peers": 20},
        "disk": {"total": 2_500_000_000_000, "free": 2_000_000_000_000, "used_pct": 20.0},
        "helper": {"repo": {"behind": 0, "can_apply": False, "pins": {"geth": "v3.3.0", "beacon": "v2.3.0"},
                            "head_short": "abc1234", "rollback_to": None, "blocked_reasons": []},
                   "containers": {"pulse-geth": {"running": True, "status": "running"}}, "system": {}},
        "running": None, "queued": 0, "history": [],
        "readiness": {"ready": 0.0, "synced": 0.0, "peers_ok": 1.0, "clock_ok": 1.0, "clean_days": 0.0, "ready_pct": 99.2,
                      "uptime_pct": 99.9, "downtime_min": 12.0, "outages": 1.0, "history_days": 3.5, "inbound_avg": 4.2},
    }
    for k, v in over.items():
        s[k] = v
    if "validator" not in over:
        s["validator"] = control.validator_state(s)
    s["health"] = control.health(s)
    return s


def with_validator(enabled=True, running=True, started_at="2026-10-17T10:00:00.123456789Z", **metrics):
    """fake_status with the helper reporting a validator (and Prometheus answering with metrics)."""
    control.validator_metrics = lambda: dict(metrics)
    helper = fake_status()["helper"]
    helper["validator"] = {"enabled": enabled, "since": "2026-10-17T09:00:00Z" if enabled else None,
                           "fee_recipient": "0x000000000000000000000000000000000000dEaD"}
    helper["containers"]["pulse-validator"] = ({"running": running, "status": "running" if running else "exited",
                                                "started_at": started_at} if enabled else
                                               {"running": False, "status": "not installed"})
    return fake_status(helper=helper)


class AppTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = os.path.join(self.tmp, "state"); os.makedirs(os.path.join(self.state, "logs"))
        self.req = os.path.join(self.tmp, "requests"); os.makedirs(self.req)
        control.STATE_DIR, control.REQ_DIR = self.state, self.req
        self._orig_report = control.HOST_REPORT
        control.HOST_REPORT = os.path.join(self.tmp, "no-report.txt")
        self.status = fake_status()
        self._orig = control.collect_status
        self._orig_vm = control.validator_metrics
        control.collect_status = lambda: self.status
        self.app = control.create_app({
            "TESTING": True, "SECRET_KEY": "test-secret",
            "PASSWORD_HASH": generate_password_hash(PASSWORD), "TRUSTED_HOSTS": ["rpc.home"],
        })
        self.c = self.app.test_client()

    def tearDown(self):
        control.collect_status = self._orig
        control.validator_metrics = self._orig_vm
        control.HOST_REPORT = self._orig_report

    def csrf(self, path="/login"):
        html = self.c.get(path, base_url=BASE).get_data(as_text=True)
        return re.search(r'name="csrf" value="([^"]+)"', html).group(1)

    def login(self, pw=PASSWORD):
        return self.c.post("/login", base_url=BASE, data={"csrf": self.csrf(), "password": pw})

    def requests(self):
        return [f for f in os.listdir(self.req) if f.endswith(".json")]

    # --- auth -----------------------------------------------------------------
    def test_pages_require_login(self):
        r = self.c.get("/", base_url=BASE)
        self.assertEqual(r.status_code, 302); self.assertIn("/login", r.location)
        self.assertEqual(self.c.get("/api/status", base_url=BASE).status_code, 401)
        self.assertEqual(self.c.get("/fragment/status", base_url=BASE).status_code, 401)

    def test_home_screen_files_are_public(self):
        for path, ctype in (("/favicon.ico", "image/vnd.microsoft.icon"),
                            ("/apple-touch-icon.png", "image/png"), ("/icon-512.png", "image/png"),
                            ("/manifest.webmanifest", "application/manifest+json"),
                            ("/static/favicon.svg", "image/svg+xml"), ("/static/favicon-32.png", "image/png")):
            r = self.c.get(path, base_url=BASE)  # signed out
            self.assertEqual(r.status_code, 200, path); self.assertEqual(r.mimetype, ctype, path)
        m = json.loads(self.c.get("/manifest.webmanifest", base_url=BASE).get_data(as_text=True))
        self.assertEqual(m["display"], "standalone"); self.assertLessEqual(len(m["short_name"]), 12)
        # Only those exact files: pages and data still need sign-in.
        self.assertEqual(self.c.get("/", base_url=BASE).status_code, 302)
        self.assertEqual(self.c.get("/api/status", base_url=BASE).status_code, 401)
        self.assertEqual(self.c.get("/app.css", base_url=BASE).status_code, 404)  # nothing else at the root
        login = self.c.get("/login", base_url=BASE).get_data(as_text=True)  # iOS may add it from the sign-in page
        self.assertIn('rel="apple-touch-icon"', login); self.assertIn('rel="manifest"', login)

    def test_login_post_needs_csrf(self):
        r = self.c.post("/login", base_url=BASE, data={"password": PASSWORD})
        self.assertEqual(r.status_code, 400)

    def test_wrong_then_right_password_and_cookie_flags(self):
        self.assertEqual(self.login("nope").status_code, 401)
        r = self.login()
        self.assertEqual(r.status_code, 302)
        cookie = [h for h in r.headers.getlist("Set-Cookie") if h.startswith("__Host-control=")][-1]
        for flag in ("Secure", "HttpOnly", "SameSite=Strict", "Path=/"):
            self.assertIn(flag, cookie)
        self.assertNotIn("Domain=", cookie)
        self.assertEqual(self.c.get("/", base_url=BASE).status_code, 200)

    def test_rate_limit_blocks_even_the_right_password(self):
        for _ in range(control.LOGIN_MAX_PER_IP):
            self.assertEqual(self.login("wrong").status_code, 401)
        self.assertEqual(self.login().status_code, 429)

    def test_no_password_configured(self):
        self.app.config["PASSWORD_HASH"] = ""
        r = self.login()
        self.assertEqual(r.status_code, 401)
        self.assertIn("set-password.sh", r.get_data(as_text=True))

    def test_untrusted_host_rejected(self):
        self.assertEqual(self.c.get("/login", base_url="https://evil.example").status_code, 400)

    def test_logout_needs_csrf(self):
        self.login()
        self.assertEqual(self.c.post("/logout", base_url=BASE).status_code, 400)

    def test_security_headers(self):
        r = self.c.get("/login", base_url=BASE)
        self.assertIn("script-src 'self'", r.headers["Content-Security-Policy"])
        self.assertNotIn("unsafe-inline", r.headers["Content-Security-Policy"])
        self.assertEqual(r.headers["X-Frame-Options"], "DENY")
        self.assertEqual(r.headers["Cache-Control"], "no-store")

    # --- dashboard + actions ---------------------------------------------------
    def test_dashboard_renders_status(self):
        self.login()
        html = self.c.get("/", base_url=BASE).get_data(as_text=True)
        self.assertIn("Downloading blocks", html); self.assertIn("v3.3.0", html); self.assertIn("Attention", html)
        self.assertNotIn("style=", html)  # CSP forbids inline styles
        self.assertIn("Restart go-pulse", html); self.assertNotIn(">Apply update<", html)

    def test_action_needs_confirmation_then_writes_one_request(self):
        self.login()
        tok = self.csrf("/")
        r = self.c.post("/action/restart-geth", base_url=BASE, data={"csrf": tok})
        self.assertEqual(r.status_code, 200); self.assertIn("Restart go-pulse?", r.get_data(as_text=True))
        self.assertEqual(self.requests(), [])
        r = self.c.post("/action/restart-geth", base_url=BASE, data={"csrf": tok, "confirmed": "yes"})
        self.assertEqual(r.status_code, 302)
        files = self.requests(); self.assertEqual(len(files), 1)
        path = os.path.join(self.req, files[0])
        with open(path) as fh:
            req = json.load(fh)
        self.assertEqual(req["action"], "restart-geth"); self.assertRegex(req["id"], r"^[0-9a-f]{16}$")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode) & 0o007, 0)  # not world-readable
        # A second action while one is queued is refused.
        self.status = fake_status(queued=1)
        self.c.post("/action/restart-node", base_url=BASE, data={"csrf": tok, "confirmed": "yes"})
        self.assertEqual(len(self.requests()), 1)
        self.assertIn("still running", self.c.get("/", base_url=BASE).get_data(as_text=True))

    def test_stop_needs_password_start_does_not(self):
        self.login()
        tok = self.csrf("/")
        self.assertIn("Stop the node", self.c.get("/", base_url=BASE).get_data(as_text=True))
        html = self.c.post("/action/stop-node", base_url=BASE, data={"csrf": tok}).get_data(as_text=True)
        self.assertIn('name="password"', html)                           # confirm screen asks for it
        r = self.c.post("/action/stop-node", base_url=BASE, data={"csrf": tok, "confirmed": "yes"})
        self.assertEqual(r.status_code, 401); self.assertEqual(self.requests(), [])
        r = self.c.post("/action/stop-node", base_url=BASE, data={"csrf": tok, "confirmed": "yes", "password": "nope"})
        self.assertEqual(r.status_code, 401); self.assertIn("Wrong password", r.get_data(as_text=True))
        self.assertEqual(self.requests(), [])
        r = self.c.post("/action/stop-node", base_url=BASE, data={"csrf": tok, "confirmed": "yes", "password": PASSWORD})
        self.assertEqual(r.status_code, 302); self.assertEqual(len(self.requests()), 1)
        for f in self.requests():
            os.remove(os.path.join(self.req, f))
        # Start: confirm screen without a password field, then straight through.
        self.status = fake_status(stopped={"at": "2026-10-17T19:00:00+00:00"})
        html = self.c.post("/action/start-node", base_url=BASE, data={"csrf": tok}).get_data(as_text=True)
        self.assertNotIn('name="password"', html)
        r = self.c.post("/action/start-node", base_url=BASE, data={"csrf": tok, "confirmed": "yes"})
        self.assertEqual(r.status_code, 302); self.assertEqual(len(self.requests()), 1)

    def test_stop_password_counts_toward_lockout(self):
        self.login()
        tok = self.csrf("/")
        for _ in range(control.LOGIN_MAX_PER_IP):
            self.c.post("/action/stop-node", base_url=BASE, data={"csrf": tok, "confirmed": "yes", "password": "x"})
        r = self.c.post("/action/stop-node", base_url=BASE, data={"csrf": tok, "confirmed": "yes", "password": PASSWORD})
        self.assertEqual(r.status_code, 429); self.assertEqual(self.requests(), [])

    def test_stopped_banner_and_buttons(self):
        self.login()
        self.status = fake_status(stopped={"at": "2026-10-17T19:00:00+00:00"})
        self.assertEqual(self.status["health"][0], "red")
        html = self.c.get("/", base_url=BASE).get_data(as_text=True)
        self.assertIn("stopped on purpose", html); self.assertIn("Start the node", html)
        self.assertNotIn("Stop the node", html); self.assertNotIn("Restart go-pulse", html)
        tok = self.csrf("/")
        self.c.post("/action/restart-geth", base_url=BASE, data={"csrf": tok, "confirmed": "yes"})
        self.assertEqual(self.requests(), [])                            # refused while stopped
        # Stopped over SSH (no stopped.json): Start is offered, Stop isn't.
        st = fake_status(); st["helper"]["containers"] = {"pulse-geth": {"running": False, "status": "not installed"},
                                                           "pulse-beacon": {"running": False, "status": "not installed"}}
        self.status = st
        html = self.c.get("/", base_url=BASE).get_data(as_text=True)
        self.assertIn("Start the node", html); self.assertNotIn("Stop the node", html)

    # --- on-chain key check -------------------------------------------------------
    PK = "0x" + "ab" * 48
    ADDR = "0xea4225FC2DfC4c51B351bFdfAD2E1Dc9Fe64894d"

    @staticmethod
    def deposit_log(pubkey, address, amount_gwei=32_000_000 * 10**9, index=7, block=1000):
        """An ABI-encoded DepositEvent, as eth_getLogs returns it."""
        wc = bytes.fromhex("01" + "00" * 11 + address[2:].lower())
        fields = [bytes.fromhex(pubkey[2:]), wc, amount_gwei.to_bytes(8, "little"), b"\x11" * 96, index.to_bytes(8, "little")]
        head, tail = b"", b""
        for f in fields:
            head += (5 * 32 + len(tail)).to_bytes(32, "big")
            tail += len(f).to_bytes(32, "big") + f + b"\x00" * (-len(f) % 32)
        return {"data": "0x" + (head + tail).hex(), "blockNumber": hex(block), "transactionHash": "0x" + "cd" * 32}

    def fake_chain(self, beacon=None, logs=(), beacon_fail=False, rpc_fail=False):
        """Point the check at canned answers instead of the node."""
        seen = {}
        orig_get, orig_rpc = control._get_json, control._rpc

        def get_json(url, timeout=3):
            seen["beacon_url"] = url
            if beacon_fail:
                raise OSError("connection refused")
            if beacon == 404:
                raise control.urllib.error.HTTPError(url, 404, "Not Found", {}, None)
            return {"data": [beacon] if beacon else []}

        def rpc(method, params, timeout=15):
            if rpc_fail:
                raise OSError("rpc down")
            if method == "eth_blockNumber":
                return hex(100_000)
            seen["logs_filter"] = params[0]
            return list(logs)
        control._get_json, control._rpc = get_json, rpc
        self.addCleanup(setattr, control, "_get_json", orig_get)
        self.addCleanup(setattr, control, "_rpc", orig_rpc)
        return seen

    def beacon_entry(self, status="active_ongoing", address=None, slashed=False):
        wc = "0x01" + "00" * 11 + (address or self.ADDR)[2:].lower()
        return {"index": "4242", "status": status, "balance": "32000001000000000",
                "validator": {"pubkey": self.PK, "withdrawal_credentials": wc, "effective_balance": "32000000000000000",
                              "slashed": slashed, "activation_eligibility_epoch": "10", "activation_epoch": "12",
                              "exit_epoch": "18446744073709551615"}}

    def test_parse_deposit_log_and_withdrawal_target(self):
        d = control.parse_deposit_log(self.deposit_log(self.PK, self.ADDR)["data"])
        self.assertEqual(d["pubkey"], self.PK)
        self.assertEqual(d["amount_gwei"], 32_000_000 * 10**9); self.assertEqual(d["index"], 7)
        self.assertEqual(control.withdrawal_target(d["withdrawal_credentials"]),
                         ("0x01 (execution address)", self.ADDR.lower()))
        self.assertIsNone(control.withdrawal_target("0x00" + "11" * 31)[1])

    def test_check_no_deposit_yet(self):
        seen = self.fake_chain(beacon=None, logs=[self.deposit_log("0x" + "cd" * 48, self.ADDR)])  # someone else's key
        r = control.chain_check(self.PK, self.ADDR)
        self.assertEqual(r["verdict"][:2], ("green", "No deposit for this key yet"))
        self.assertIsNone(r["beacon"]); self.assertEqual(r["recent"], [])
        self.assertIn("?id=" + self.PK, seen["beacon_url"])
        f = seen["logs_filter"]
        self.assertEqual(f["address"], control.DEPOSIT_CONTRACT); self.assertEqual(f["topics"], [control.DEPOSIT_EVENT_TOPIC])
        self.assertEqual(int(f["fromBlock"], 16), 100_000 - control.DEPOSIT_SCAN_BLOCKS)
        self.fake_chain(beacon=404)  # Prysm may answer 404 for an unknown key
        self.assertEqual(control.chain_check(self.PK, self.ADDR)["verdict"][0], "green")

    def test_check_front_run_deposit_is_red(self):
        self.fake_chain(logs=[self.deposit_log(self.PK, "0x" + "66" * 20)])
        r = control.chain_check(self.PK, self.ADDR)
        self.assertEqual(r["verdict"][:2], ("red", "Withdrawal credentials don't match your address"))
        self.assertIs(r["recent"][0]["withdrawal"]["matches"], False)

    def test_check_own_deposit_pending_then_active(self):
        self.fake_chain(logs=[self.deposit_log(self.PK, self.ADDR)])
        r = control.chain_check(self.PK, self.ADDR)
        self.assertEqual(r["verdict"][:2], ("yellow", "Deposit seen, not processed yet"))
        self.assertIs(r["recent"][0]["withdrawal"]["matches"], True)
        self.fake_chain(beacon=self.beacon_entry("pending_queued"))
        self.assertEqual(control.chain_check(self.PK, self.ADDR)["verdict"][:2], ("green", "On chain: Pending"))
        self.fake_chain(beacon=self.beacon_entry("active_ongoing"))
        r = control.chain_check(self.PK, self.ADDR.lower())
        self.assertEqual(r["verdict"][:2], ("green", "On chain: Active"))
        self.assertEqual(r["beacon"]["index"], "4242"); self.assertIs(r["beacon"]["withdrawal"]["matches"], True)
        self.fake_chain(beacon=self.beacon_entry("active_ongoing", address="0x" + "66" * 20))
        self.assertEqual(control.chain_check(self.PK, self.ADDR)["verdict"][0], "red")
        self.fake_chain(beacon=self.beacon_entry("active_slashed", slashed=True))
        self.assertEqual(control.chain_check(self.PK, self.ADDR)["verdict"][0], "red")

    def test_check_errors_are_yellow_not_green(self):
        self.fake_chain(beacon_fail=True)
        self.assertEqual(control.chain_check(self.PK, self.ADDR)["verdict"][:2], ("yellow", "Couldn't check the beacon state"))
        self.fake_chain(rpc_fail=True)
        self.assertEqual(control.chain_check(self.PK, self.ADDR)["verdict"][0], "yellow")

    def test_check_without_expected_address_does_not_compare(self):
        self.fake_chain(beacon=self.beacon_entry("active_ongoing", address="0x" + "66" * 20))
        r = control.chain_check(self.PK, "")
        self.assertEqual(r["verdict"][:2], ("green", "On chain: Active")); self.assertIsNone(r["beacon"]["withdrawal"]["matches"])

    def test_check_page(self):
        self.assertEqual(self.c.get("/validator/check", base_url=BASE).status_code, 302)  # signed out
        self.login()
        self.fake_chain(beacon=self.beacon_entry("pending_initialized"))
        orig = (control.CHECK_PUBKEYS, control.CHECK_ADDRESS)
        self.addCleanup(lambda: setattr(control, "CHECK_PUBKEYS", orig[0]) or setattr(control, "CHECK_ADDRESS", orig[1]))
        control.CHECK_PUBKEYS, control.CHECK_ADDRESS = [self.PK], self.ADDR
        html = self.c.get("/validator/check?mode=status", base_url=BASE).get_data(as_text=True)
        for text in ("Validator status on chain", "On chain: Pending", self.PK, "pending_initialized", "4242",
                     "32,000,001 PLS", self.ADDR.lower(), "matches", "control/.env"):
            self.assertIn(text, html)
        html = self.c.get("/validator/check", base_url=BASE).get_data(as_text=True)
        self.assertIn("Deposits for the validator key", html)
        r = self.c.get("/validator/check?pubkey=0x1234", base_url=BASE)
        self.assertEqual(r.status_code, 400); self.assertIn("isn&#39;t a validator public key", r.get_data(as_text=True))
        other = "cd" * 48  # pasted without 0x
        self.fake_chain(beacon=None)
        html = self.c.get(f"/validator/check?pubkey={other}", base_url=BASE).get_data(as_text=True)
        self.assertIn("0x" + other, html); self.assertIn("No deposit for this key yet", html)
        control.CHECK_PUBKEYS = []
        html = self.c.get("/validator/check", base_url=BASE).get_data(as_text=True)
        self.assertIn("No validator key to check", html)

    def test_check_buttons_on_validator_card(self):
        self.login()
        self.status = with_validator(enabled=False)
        html = self.c.get("/", base_url=BASE).get_data(as_text=True)
        self.assertIn("Check deposits", html); self.assertIn("Check status &amp; withdrawal", html)
        self.assertIn('href="/validator/check?mode=status"', html)
        self.status = with_validator(status=3.0)
        self.assertIn("Check deposits", self.c.get("/", base_url=BASE).get_data(as_text=True))

    # --- validator card ----------------------------------------------------------
    def test_no_validator_card_without_helper_report(self):
        self.login()
        self.assertNotIn('id="validator"', self.c.get("/", base_url=BASE).get_data(as_text=True))

    def test_validator_switched_off(self):
        self.login()
        self.status = with_validator(enabled=False)
        self.assertEqual(self.status["validator"]["state"], "off")
        html = self.c.get("/", base_url=BASE).get_data(as_text=True)
        self.assertIn("Switched off", html); self.assertIn("sudo ./validator/enable.sh", html)
        self.assertNotIn("Stop the validator", html); self.assertNotIn("Start the validator", html)
        self.assertNotIn("validator", self.status["health"][1])
        tok = self.csrf("/")
        r = self.c.post("/action/start-validator", base_url=BASE, data={"csrf": tok, "confirmed": "yes"})
        self.assertEqual(r.status_code, 302); self.assertEqual(self.requests(), [])
        self.assertIn("isn&#39;t switched on", self.c.get("/", base_url=BASE).get_data(as_text=True))

    def test_validator_attesting_and_stop_needs_password(self):
        self.login()
        self.status = with_validator(status=3.0, balance=32000123.4, lag_slots=12.0, refusals=0.0,
                                     target_24h=0.991, attested_24h=270.0)
        v = self.status["validator"]
        self.assertEqual((v["state"], v["status_text"]), ("running", "Active"))
        html = self.c.get("/", base_url=BASE).get_data(as_text=True)
        for text in ("Attesting", "32,000,123 PLS", "12 slots ago", "99.1%", "270 attestations",
                     "0x000000000000000000000000000000000000dEaD", "Stop the validator"):
            self.assertIn(text, html)
        self.assertNotIn("Start the validator", html)
        tok = self.csrf("/")
        html = self.c.post("/action/stop-validator", base_url=BASE, data={"csrf": tok}).get_data(as_text=True)
        self.assertIn('name="password"', html); self.assertIn("not an exit", html)
        r = self.c.post("/action/stop-validator", base_url=BASE, data={"csrf": tok, "confirmed": "yes", "password": "no"})
        self.assertEqual(r.status_code, 401); self.assertEqual(self.requests(), [])
        r = self.c.post("/action/stop-validator", base_url=BASE, data={"csrf": tok, "confirmed": "yes", "password": PASSWORD})
        self.assertEqual(r.status_code, 302); self.assertEqual(len(self.requests()), 1)
        with open(os.path.join(self.req, self.requests()[0])) as fh:
            self.assertEqual(json.load(fh)["action"], "stop-validator")

    def test_validator_stopped_is_a_problem_and_start_needs_no_password(self):
        self.login()
        self.status = with_validator(running=False)
        self.assertEqual(self.status["validator"]["state"], "stopped")
        self.assertEqual(self.status["health"][0], "red")
        self.assertIn("validator switched on but not running", self.status["health"][1])
        html = self.c.get("/", base_url=BASE).get_data(as_text=True)
        self.assertIn("Start the validator", html); self.assertNotIn("Stop the validator", html)
        tok = self.csrf("/")
        html = self.c.post("/action/start-validator", base_url=BASE, data={"csrf": tok}).get_data(as_text=True)
        self.assertNotIn('name="password"', html)
        r = self.c.post("/action/start-validator", base_url=BASE, data={"csrf": tok, "confirmed": "yes"})
        self.assertEqual(r.status_code, 302); self.assertEqual(len(self.requests()), 1)
        for f in self.requests():
            os.remove(os.path.join(self.req, f))
        # Not while the node is stopped on purpose.
        st = with_validator(running=False); st["stopped"] = {"at": "2026-10-17T19:00:00+00:00"}
        self.status = st
        self.c.post("/action/start-validator", base_url=BASE, data={"csrf": tok, "confirmed": "yes"})
        self.assertEqual(self.requests(), [])

    def test_validator_doppelganger_and_problems(self):
        from datetime import datetime, timedelta, timezone
        just = (datetime.now(timezone.utc) - timedelta(minutes=3)).strftime("%Y-%m-%dT%H:%M:%S.123456789Z")
        st = with_validator(started_at=just, status=3.0, lag_slots=400.0)
        self.assertEqual(st["validator"]["state"], "doppelganger")
        self.assertNotIn("missing attestations", st["health"][1])  # expected during the wait
        st = with_validator(status=3.0, lag_slots=400.0)
        self.assertIn("validator is missing attestations", st["health"][1])
        st = with_validator(status=5.0)
        self.assertEqual(st["health"][0], "red"); self.assertIn("validator is slashing", st["health"][1])
        st = with_validator(status=3.0, refusals=1.0)
        self.assertIn("slashing protection refused", st["health"][1])
        self.assertIsNone(control._age_seconds("garbage"))
        self.assertLess(abs(control._age_seconds(just) - 180), 5)

    def test_action_csrf_and_unknown(self):
        self.login()
        self.assertEqual(self.c.post("/action/restart-geth", base_url=BASE, data={"confirmed": "yes"}).status_code, 400)
        tok = self.csrf("/")
        self.assertEqual(self.c.post("/action/rm-rf", base_url=BASE, data={"csrf": tok, "confirmed": "yes"}).status_code, 404)
        self.assertEqual(self.requests(), [])

    def test_apply_update_only_when_available(self):
        self.login()
        tok = self.csrf("/")
        self.c.post("/action/apply-update", base_url=BASE, data={"csrf": tok, "confirmed": "yes"})
        self.assertEqual(self.requests(), [])
        self.assertIn("Already up to date", self.c.get("/", base_url=BASE).get_data(as_text=True))
        repo = dict(self.status["helper"]["repo"], behind=2, can_apply=True,
                    incoming=[{"sha": "def5678", "date": "2026-10-20", "subject": "Bump go-pulse"}])
        self.status = fake_status(helper=dict(self.status["helper"], repo=repo))
        self.assertIn(">Apply update<", self.c.get("/", base_url=BASE).get_data(as_text=True))
        self.c.post("/action/apply-update", base_url=BASE, data={"csrf": tok, "confirmed": "yes"})
        self.assertEqual(len(self.requests()), 1)

    def test_no_helper_disables_actions(self):
        self.status = fake_status(helper=None)
        self.login()
        tok = self.csrf("/")
        self.c.post("/action/restart-geth", base_url=BASE, data={"csrf": tok, "confirmed": "yes"})
        self.assertEqual(self.requests(), [])

    def test_log_route_only_accepts_ids(self):
        self.login()
        rid = "0123456789abcdef"
        with open(os.path.join(self.state, "logs", f"{rid}.log"), "w") as fh:
            fh.write("hello log")
        self.assertIn("hello log", self.c.get(f"/log/{rid}", base_url=BASE).get_data(as_text=True))
        for bad in ("..%2f..%2fetc%2fpasswd", "ZZZZ", "0123456789abcdeg"):
            self.assertEqual(self.c.get(f"/log/{bad}", base_url=BASE).status_code, 404)

    # --- wallet settings + readiness ---------------------------------------------
    def test_wallet_settings_card(self):
        self.login()
        html = self.c.get("/", base_url=BASE).get_data(as_text=True)
        self.assertIn("Wallet settings", html)
        for text in ("<code>369</code>", "<code>https://rpc.home</code>", "<code>PLS</code>", "wss://rpc.home",
                     "https://scan.pulsechain.com", 'data-copy="369"', 'data-chain-id="0x171"', "Add to MetaMask"):
            self.assertIn(text, html)
        self.assertNotIn("style=", html)

    def test_readiness_card(self):
        self.login()
        html = self.c.get("/fragment/status", base_url=BASE).get_data(as_text=True)
        self.assertIn("Validator readiness", html); self.assertIn("Not ready", html)
        self.assertIn("0.0 of 30 clean days", html); self.assertIn("99.90%", html)
        self.assertIn("99.20% · goal 99.5%", html)  # ready % below the goal is marked
        self.assertRegex(html, r'<dd class="bad">99\.20%'); self.assertIn("12 min down, 1 outage", html)
        self.status = fake_status(readiness=None)
        html = self.c.get("/fragment/status", base_url=BASE).get_data(as_text=True)
        self.assertIn("./monitoring/install.sh", html)

    def test_readiness_queries(self):
        orig = control.prom_scalar
        try:
            control._readiness_cache.update(at=0.0, data=None)
            control.prom_scalar = lambda expr: {"pulse:ready": 1.0}.get(expr, 2.0)
            r = control.readiness()
            self.assertEqual(r["ready"], 1.0); self.assertEqual(r["uptime_pct"], 2.0)
            self.assertEqual(set(r), set(control.READINESS_QUERIES))
            # Prometheus missing -> None (and cached, not retried on every refresh)
            control._readiness_cache.update(at=0.0, data=None)
            def boom(expr):
                raise OSError("connection refused")
            control.prom_scalar = boom
            self.assertIsNone(control.readiness())
            # Rules not loaded yet (pulse:ready has no data) -> None
            control._readiness_cache.update(at=0.0, data=None)
            control.prom_scalar = lambda expr: None
            self.assertIsNone(control.readiness())
        finally:
            control.prom_scalar = orig
            control._readiness_cache.update(at=0.0, data=None)

    # --- console --------------------------------------------------------------------
    def write_live(self, container, seq, lines):
        os.makedirs(os.path.join(self.state, "live"), exist_ok=True)
        with open(os.path.join(self.state, "live", f"{container}.log"), "w") as fh:
            fh.write(f"#seq {seq}\n" + "\n".join(lines) + "\n")

    def test_console_requires_login_and_renders(self):
        self.assertEqual(self.c.get("/console", base_url=BASE).status_code, 302)
        self.assertEqual(self.c.get("/console/geth.json", base_url=BASE).status_code, 401)
        self.login()
        html = self.c.get("/console", base_url=BASE).get_data(as_text=True)
        self.assertIn('data-tabs="geth,beacon"', html); self.assertIn("go-pulse", html); self.assertIn("Prysm", html)
        self.assertNotIn("style=", html)
        self.assertIn('<main class="wide">', html)          # console uses the whole window width
        self.assertIn('id="console-wrap"', html); self.assertIn('id="console-full"', html)
        self.assertNotIn('class="wide"', self.c.get("/", base_url=BASE).get_data(as_text=True))  # dashboard stays narrow

    def test_console_incremental_lines(self):
        self.login()
        self.write_live("pulse-geth", 10, [f"line {i}" for i in range(6, 11)])  # lines 6..10
        d = self.c.get("/console/geth.json", base_url=BASE).get_json()
        self.assertEqual(d["seq"], 10); self.assertEqual(d["lines"][0], "line 6"); self.assertEqual(len(d["lines"]), 5)
        d = self.c.get("/console/geth.json?after=8", base_url=BASE).get_json()
        self.assertEqual(d["lines"], ["line 9", "line 10"]); self.assertFalse(d["reset"])
        d = self.c.get("/console/geth.json?after=10", base_url=BASE).get_json()
        self.assertEqual(d["lines"], [])
        d = self.c.get("/console/geth.json?after=2", base_url=BASE).get_json()   # fell behind the window
        self.assertTrue(d["reset"]); self.assertEqual(len(d["lines"]), 5)
        d = self.c.get("/console/geth.json?after=99", base_url=BASE).get_json()  # helper restarted (seq went back)
        self.assertTrue(d["reset"])
        d = self.c.get("/console/geth.json?after=abc", base_url=BASE).get_json()
        self.assertEqual(len(d["lines"]), 5)

    def test_console_missing_and_unknown(self):
        self.login()
        self.assertTrue(self.c.get("/console/beacon.json", base_url=BASE).get_json()["missing"])
        for bad in ("caddy", "..%2fstatus", "pulse-geth"):
            self.assertEqual(self.c.get(f"/console/{bad}.json", base_url=BASE).status_code, 404)

    def test_console_does_not_render_log_html(self):
        self.login()
        self.write_live("pulse-geth", 1, ['<script>alert(1)</script> INFO x'])
        r = self.c.get("/console/geth.json", base_url=BASE)
        self.assertEqual(r.mimetype, "application/json")
        self.assertEqual(r.get_json()["lines"], ['<script>alert(1)</script> INFO x'])  # data, rendered with textContent

    # --- sync phases ------------------------------------------------------------------
    def test_sync_phases(self):
        base = {"up": True, "peers": 30}
        self.assertEqual(control.sync_phase({"up": False}), "down")
        self.assertEqual(control.sync_phase(dict(base, syncing=False, current=5, highest=5)), "synced")
        self.assertEqual(control.sync_phase(dict(base, syncing=True, current=0, highest=0)), "starting")
        self.assertEqual(control.sync_phase(dict(base, syncing=True, current=100, highest=200)), "blocks")
        # The screenshot case: all blocks in, current briefly above highest, still healing.
        self.assertEqual(control.sync_phase(dict(base, syncing=True, current=27825980, highest=27825849)), "state")

    def test_healing_phase_wording(self):
        el = {"up": True, "syncing": True, "current": 27825980, "highest": 27825849, "peers": 150, "percent": 100.0,
              "accounts": 287243768, "healed": 1599660, "healing_pending": 4200}
        el["phase"] = control.sync_phase(el)
        self.status = fake_status(el=el, heal_per_min=5321.7)
        self.assertEqual(self.status["health"], ("yellow", "syncing (blocks done, healing state: final step)"))
        self.login()
        html = self.c.get("/fragment/status", base_url=BASE).get_data(as_text=True)
        self.assertIn("Final step: healing state", html); self.assertIn("all in", html)
        self.assertIn("1,599,660 trie nodes fixed", html); self.assertIn("5,321/min", html); self.assertIn("4,200 queued", html)
        self.assertNotIn("27,825,980 of 27,825,849", html); self.assertNotIn("100.0%", html)

    def test_blocks_phase_unchanged(self):
        self.login()
        html = self.c.get("/fragment/status", base_url=BASE).get_data(as_text=True)
        self.assertIn("Downloading blocks", html); self.assertIn("100 of 200", html); self.assertIn("50.0%", html)

    # --- host (hypervisor) report --------------------------------------------------
    REPORT = """#pve-host-report 1
generated {gen}
pve · up 3 days · guests 3/3 running · UPS OL 100% 73 min
last drive check: 2026-11-06, 3 days ago

== Host ==
    pve-manager/9.2.26 · kernel 7.0.14-28-pve
  ✓ running the newest installed kernel
  ! 4 package updates pending (apt list --upgradable)

== Guests ==
  ✓ 100 plex running
  ✗ 101 rpc: status: stopped
  ✓ <b>not html</b>

== Summary ==
  ! 4 package updates pending (apt list --upgradable)
  ✗ 101 rpc: status: stopped

== Before a host reboot or shutdown ==
    1. Plex: check the DVR schedule.
"""

    def write_report(self, text, age=60):
        path = os.path.join(self.tmp, "report.txt")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        t = time.time() - age
        os.utime(path, (t, t))
        control.HOST_REPORT = path
        return path

    def test_host_report_parse_and_card(self):
        gen = datetime.fromtimestamp(time.time() - 120).astimezone().isoformat(timespec="seconds")
        self.write_report(self.REPORT.format(gen=gen), age=60)
        r = control.host_report()
        self.assertEqual((r["level"], r["bad"], r["warn"]), ("red", 1, 1))
        self.assertFalse(r["stale"]); self.assertGreaterEqual(r["age"], 115)  # generated time wins over the file time
        self.assertEqual(r["header"][0], "pve · up 3 days · guests 3/3 running · UPS OL 100% 73 min")
        self.status["host"] = r
        self.login()
        html = self.c.get("/fragment/status", base_url=BASE).get_data(as_text=True)
        self.assertIn("Host (hypervisor)", html); self.assertIn("1 problem", html)
        self.assertIn("101 rpc: status: stopped", html); self.assertIn('href="/host"', html)
        page = self.c.get("/host", base_url=BASE).get_data(as_text=True)
        self.assertIn("Before a host reboot or shutdown", page); self.assertIn("pve-manager/9.2.26", page)
        self.assertIn("&lt;b&gt;not html&lt;/b&gt;", page); self.assertNotIn("<b>not html</b>", page)

    def test_host_report_clean_stale_missing(self):
        self.write_report("pve\n\n== Summary ==\n  ✓ everything checked looks fine\n", age=10)  # no generated line
        self.assertEqual(control.host_report()["level"], "green")
        self.write_report("x\n\n== Summary ==\n  ✓ everything checked looks fine\n", age=control.HOST_REPORT_STALE + 60)
        r = control.host_report()
        self.assertTrue(r["stale"]); self.assertEqual(r["level"], "yellow"); self.assertIn("No report for", r["headline"])
        self.write_report("cut off mid-run\n== Host ==\n  ✓ fine\n", age=10)
        self.assertEqual(control.host_report()["headline"], "Report incomplete (no summary)")
        control.HOST_REPORT = os.path.join(self.tmp, "missing.txt")
        self.assertIsNone(control.host_report())
        self.login()
        self.assertNotIn("Host (hypervisor)", self.c.get("/fragment/status", base_url=BASE).get_data(as_text=True))
        self.assertIn("No report has arrived yet", self.c.get("/host", base_url=BASE).get_data(as_text=True))

    def test_host_page_requires_login(self):
        r = self.c.get("/host", base_url=BASE)
        self.assertEqual(r.status_code, 302); self.assertIn("/login", r.location)

    # --- health -----------------------------------------------------------------
    def test_health_levels(self):
        synced = {"up": True, "syncing": False, "current": 5, "highest": 5, "peers": 30}
        cl_ok = {"up": True, "syncing": False, "el_offline": False, "peers": 20}
        s = fake_status(el=synced, cl=cl_ok)
        self.assertEqual(control.health(s)[0], "green")
        self.assertEqual(control.health(fake_status(el={"up": False}))[0], "red")
        s = fake_status(el=synced, cl=cl_ok, disk={"total": 1, "free": 0, "used_pct": 95.0})
        self.assertEqual(control.health(s)[0], "red")


if __name__ == "__main__":
    unittest.main()
