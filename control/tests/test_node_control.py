"""node-control helper against real temporary git repos, with fake docker/update.sh."""
import datetime as dt
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("node_control", os.path.join(HERE, "..", "node-control.py"))
nc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nc)

COMMON = 'GETH_IMAGE_PINNED="registry.gitlab.com/pulsechaincom/go-pulse:{g}@sha256:aa"\n' \
         'BEACON_IMAGE_PINNED="registry.gitlab.com/pulsechaincom/prysm-pulse/beacon-chain:{b}@sha256:bb"\n'


def sh(cmd, cwd):
    subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True)


class NodeControlTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.origin = os.path.join(self.tmp, "origin.git")
        self.repo = os.path.join(self.tmp, "repo")
        self.work = os.path.join(self.tmp, "upstream-work")  # where "merged PRs" are made
        self.state = os.path.join(self.tmp, "state")
        self.req = os.path.join(self.tmp, "requests")
        self.calls = os.path.join(self.tmp, "calls.log")
        os.makedirs(self.state); os.makedirs(self.req)
        git_env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@t"}
        os.environ.update(git_env)
        sh(["git", "init", "-q", "--bare", "-b", "main", self.origin], self.tmp)
        sh(["git", "clone", "-q", self.origin, self.work], self.tmp)
        self.write("common.sh", COMMON.format(g="v3.3.0", b="v2.3.0"))
        self.write("docker-compose.yml", "services: {}\n")
        self.write("update.sh", f'#!/bin/sh\necho "update.sh ran" >> "{self.calls}"\necho pulled\n', mode=0o755)
        self.write("control/restart.sh", f'#!/bin/sh\necho "control restart" >> "{self.calls}"\n', mode=0o755)
        self.write("monitoring/prometheus/prometheus.yml", "global: {}\n")
        self.commit("initial")
        sh(["git", "clone", "-q", self.origin, self.repo], self.tmp)
        # Fake docker: log the call; `inspect` returns no containers.
        bindir = os.path.join(self.tmp, "bin"); os.makedirs(bindir)
        with open(os.path.join(bindir, "docker"), "w") as fh:
            fh.write(f'#!/bin/sh\necho "docker $*" >> "{self.calls}"\n'
                     'if [ "$1" = inspect ]; then echo "[]"; exit 1; fi\nexit 0\n')
        os.chmod(os.path.join(bindir, "docker"), 0o755)
        self.old_path = os.environ["PATH"]
        os.environ["PATH"] = bindir + os.pathsep + self.old_path
        nc.REPO, nc.STATE_DIR, nc.REQ_DIR = self.repo, self.state, self.req

    def tearDown(self):
        os.environ["PATH"] = self.old_path
        shutil.rmtree(self.tmp, ignore_errors=True)

    # --- helpers --------------------------------------------------------------
    def write(self, rel, text, mode=0o644, root=None):
        path = os.path.join(root or self.work, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(text)
        os.chmod(path, mode)

    def commit(self, msg):
        sh(["git", "add", "-A"], self.work)
        sh(["git", "commit", "-q", "-m", msg], self.work)
        sh(["git", "push", "-q", "origin", "main"], self.work)

    def head(self):
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo, capture_output=True, text=True).stdout.strip()

    def request(self, action, rid="00000000000000a1", raw=None):
        with open(os.path.join(self.req, f"1-{rid}.json"), "w") as fh:
            fh.write(raw if raw is not None else json.dumps({"id": rid, "action": action, "by": "test"}))

    def history(self):
        with open(os.path.join(self.state, "history.jsonl")) as fh:
            return [json.loads(l) for l in fh.read().splitlines()]

    def calls_log(self):
        if not os.path.exists(self.calls):
            return ""
        with open(self.calls) as fh:
            return fh.read()

    # --- tests ----------------------------------------------------------------
    def test_refresh_up_to_date(self):
        s = nc.refresh(fetch=True)
        r = s["repo"]
        self.assertTrue(r["fetch_ok"]); self.assertEqual(r["behind"], 0); self.assertFalse(r["can_apply"])
        self.assertEqual(r["pins"], {"geth": "v3.3.0", "beacon": "v2.3.0"})
        self.assertTrue(os.path.exists(os.path.join(self.state, "status.json")))

    def test_apply_update_then_rollback(self):
        before = self.head()
        self.write("common.sh", COMMON.format(g="v3.4.0", b="v2.3.0")); self.commit("Bump go-pulse to v3.4.0")
        r = nc.refresh(fetch=True)["repo"]
        self.assertEqual(r["behind"], 1); self.assertTrue(r["can_apply"])
        self.assertEqual(r["incoming_pins"]["geth"], "v3.4.0"); self.assertEqual(r["incoming_areas"], ["node"])
        self.assertEqual(r["incoming"][0]["subject"], "Bump go-pulse to v3.4.0")

        self.request("apply-update"); nc.process()
        after = self.head()
        self.assertNotEqual(after, before)
        h = self.history()[-1]
        self.assertTrue(h["ok"], h); self.assertIn("node containers updated", h["summary"])
        self.assertIn("update.sh ran", self.calls_log())
        with open(os.path.join(self.state, "status.json")) as fh:
            status = json.load(fh)
        self.assertEqual(status["repo"]["behind"], 0); self.assertEqual(status["repo"]["rollback_to"], before[:7])
        self.assertEqual(os.listdir(self.req), [])

        open(self.calls, "w").close()
        self.request("rollback", rid="00000000000000a2"); nc.process()
        self.assertEqual(self.head(), before)
        h = self.history()[-1]
        self.assertTrue(h["ok"], h); self.assertIn("rolled back", h["summary"])
        self.assertIn("update.sh ran", self.calls_log())
        self.assertFalse(os.path.exists(os.path.join(self.state, "rollback.json")))
        with open(os.path.join(self.state, "status.json")) as fh:
            self.assertEqual(json.load(fh)["repo"]["behind"], 1)

    def test_check_updates_logs_details(self):
        self.request("check-updates"); nc.process()
        h = self.history()[-1]
        self.assertEqual(h["summary"], "up to date")
        with open(os.path.join(self.state, "logs", f"{h['id']}.log")) as fh:
            self.assertIn("Up to date at", fh.read())
        self.write("common.sh", COMMON.format(g="v3.4.0", b="v2.3.0")); self.commit("Bump go-pulse to v3.4.0")
        self.write("control/app/control.py", "# new\n"); self.commit("Page tweak")
        self.write("control/install.sh", "#!/bin/sh\n"); self.commit("New unit")
        self.request("check-updates", rid="00000000000000c2"); nc.process()
        h = self.history()[-1]
        self.assertEqual(h["summary"], "3 update(s) available")
        with open(os.path.join(self.state, "logs", f"{h['id']}.log")) as fh:
            log = fh.read()
        for want in ("3 new commit(s) on origin/main:", "Bump go-pulse to v3.4.0", "Page tweak",
                     "go-pulse: v3.3.0 -> v3.4.0", "Apply update would restart: go-pulse + Prysm, this page",
                     "Afterwards, over SSH: ./control/install.sh"):
            self.assertIn(want, log)

    def test_apply_blocked_by_local_changes(self):
        self.write("common.sh", COMMON.format(g="v3.4.0", b="v2.3.0")); self.commit("bump")
        self.write("docker-compose.yml", "services: {edited: {}}\n", root=self.repo)
        before = self.head()
        self.request("apply-update"); nc.process()
        h = self.history()[-1]
        self.assertFalse(h["ok"]); self.assertIn("local changes", h["summary"])
        self.assertEqual(self.head(), before); self.assertNotIn("update.sh", self.calls_log())

    def test_monitoring_only_change_skips_node_restart(self):
        self.write("monitoring/prometheus/prometheus.yml", "global: {scrape_interval: 30s}\n"); self.commit("tune")
        self.request("apply-update"); nc.process()
        h = self.history()[-1]
        self.assertTrue(h["ok"]); self.assertIn("nothing needed restarting", h["summary"])
        self.assertNotIn("update.sh", self.calls_log())

    def test_control_change_rebuilds_page_when_installed(self):
        self.write("control/.env", "PUBLIC_HOSTNAME=rpc.home\n", root=self.repo)  # installed (gitignored in real repo)
        self.write("control/app/control.py", "# new\n"); self.commit("page tweak")
        r = nc.refresh(fetch=True)["repo"]
        self.assertEqual(r["incoming_areas"], ["control"])
        # control/.env is untracked, so the checkout is still clean.
        self.request("apply-update"); nc.process()
        self.assertIn("control restart", self.calls_log())

    def test_manual_steps_reported(self):
        areas, manual = nc.classify(["monitoring/exporter/pulse-node-metrics.py", "control/systemd/x.service",
                                     "tailscale/install.sh"])
        self.assertEqual(manual, ["./control/install.sh", "./monitoring/install.sh", "./tailscale/install.sh"])
        self.assertFalse(any(areas.values()))
        areas, manual = nc.classify(["tailscale/Corefile"])
        self.assertTrue(areas["tailscale"]); self.assertEqual(manual, [])
        # The validator is never restarted by an update, only flagged.
        areas, manual = nc.classify(["validator/docker-compose.yml", "validator/README.md"])
        self.assertFalse(any(areas.values()))
        self.assertEqual(manual, ["sudo ./validator/restart.sh (only if the validator is switched on)"])
        # node-logs.py re-executes itself; it must not trigger a page rebuild.
        areas, manual = nc.classify(["control/node-logs.py"])
        self.assertFalse(any(areas.values())); self.assertEqual(manual, [])

    def test_stop_then_start(self):
        for name in ("stop.sh", "start.sh"):
            self.write(name, f'#!/bin/sh\necho "{name} ran" >> "{self.calls}"\n', mode=0o755, root=self.repo)
        self.request("stop-node"); nc.process()
        h = self.history()[-1]
        self.assertTrue(h["ok"], h); self.assertIn("stays down until Start node", h["summary"])
        self.assertIn("stop.sh ran", self.calls_log())
        self.assertTrue(os.path.exists(os.path.join(self.state, "stopped.json")))
        self.request("start-node", rid="00000000000000d2"); nc.process()
        h = self.history()[-1]
        self.assertTrue(h["ok"], h); self.assertIn("start.sh ran", self.calls_log())
        self.assertFalse(os.path.exists(os.path.join(self.state, "stopped.json")))

    def test_restart_actions_call_compose(self):
        self.request("restart-geth"); nc.process()
        self.assertIn("docker compose restart geth", self.calls_log())
        self.request("restart-node", rid="00000000000000b2"); nc.process()
        self.assertTrue(self.history()[-1]["ok"])

    def test_bad_requests_rejected_and_removed(self):
        self.request(None, rid="c1", raw="{not json")
        self.request(None, rid="c2", raw=json.dumps({"action": "rm -rf /", "id": "x"}))
        self.request(None, rid="c3", raw="x" * (nc.MAX_REQUEST_BYTES + 10))
        nc.process()
        summaries = [h["summary"] for h in self.history()]
        self.assertEqual(len(summaries), 3)
        self.assertTrue(all(s.startswith("rejected") for s in summaries), summaries)
        self.assertEqual(os.listdir(self.req), [])
        self.assertNotIn("docker compose", self.calls_log())

    def test_rollback_without_update(self):
        self.request("rollback"); nc.process()
        h = self.history()[-1]
        self.assertFalse(h["ok"]); self.assertIn("nothing to roll back", h["summary"])


class WatchdogTest(unittest.TestCase):
    """The watchdog with a fake docker: containers' resolv.conf files and Prysm's start time."""

    T = 1_800_000_000  # "now" in the tests

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = os.path.join(self.tmp, "state"); os.makedirs(self.state)
        self.dock = os.path.join(self.tmp, "docker-state"); os.makedirs(self.dock)
        self.calls = os.path.join(self.tmp, "calls.log")
        bindir = os.path.join(self.tmp, "bin"); os.makedirs(bindir)
        # ps: names in docker-state/ps; cp: tar of docker-state/<name>/resolv.conf;
        # inspect: docker-state/inspect.json; anything else: logged, succeeds.
        with open(os.path.join(bindir, "docker"), "w") as fh:
            fh.write(f'#!/bin/sh\nD="{self.dock}"\necho "docker $*" >> "{self.calls}"\n'
                     'case "$1" in\n'
                     '  ps) cat "$D/ps" ;;\n'
                     '  cp) n="${2%%:*}"; [ -f "$D/$n/resolv.conf" ] || exit 1; COPYFILE_DISABLE=1 tar -cf - -C "$D/$n" resolv.conf ;;\n'
                     '  inspect) cat "$D/inspect.json" ;;\n'
                     'esac\nexit 0\n')
        os.chmod(os.path.join(bindir, "docker"), 0o755)
        self.old_path = os.environ["PATH"]
        os.environ["PATH"] = bindir + os.pathsep + self.old_path
        self.host_resolv = os.path.join(self.tmp, "resolv.conf")
        self.write(self.host_resolv, "# dhcpcd\nnameserver 192.0.2.53\n")
        nc.STATE_DIR, nc.REPO, nc.HOST_RESOLV = self.state, self.tmp, self.host_resolv
        self.old_peers = nc.peer_counts
        self.peers = (50, 40)
        nc.peer_counts = lambda: self.peers
        self.containers({}, beacon_started=self.T - 3600)

    def tearDown(self):
        os.environ["PATH"] = self.old_path
        nc.peer_counts = self.old_peers
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(text)

    def containers(self, resolv, beacon_started, beacon_running=True):
        """resolv: {name: resolv.conf text}; every name is listed as running."""
        self.write(os.path.join(self.dock, "ps"), "".join(f"{n}\n" for n in resolv))
        for name, text in resolv.items():
            self.write(os.path.join(self.dock, name, "resolv.conf"), text)
        started = dt.datetime.fromtimestamp(beacon_started, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.123456789Z")
        self.write(os.path.join(self.dock, "inspect.json"), json.dumps(
            [{"Name": "/pulse-beacon", "State": {"Running": beacon_running, "StartedAt": started}}]))

    def calls_log(self):
        if not os.path.exists(self.calls):
            return ""
        with open(self.calls) as fh:
            return fh.read()

    def history(self):
        path = os.path.join(self.state, "history.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as fh:
            return [json.loads(l) for l in fh.read().splitlines()]

    # --- DNS ---------------------------------------------------------------------
    def test_restarts_container_without_dns_but_not_node_clients(self):
        empty = "# Generated by Docker Engine.\n# Overrides: []\n"
        self.containers({"pulse-grafana": empty, "pulse-caddy": "nameserver 192.0.2.53\n",
                         "pulse-geth": empty, "pulse-beacon": empty, "pulse-validator": empty},
                        beacon_started=self.T - 3600)
        done = nc.watchdog(self.T)
        self.assertEqual(done, [(True, "restarted pulse-grafana: it started without a DNS server")])
        log = self.calls_log()
        self.assertIn("docker restart pulse-grafana", log)
        for name in ("pulse-caddy", "pulse-geth", "pulse-beacon", "pulse-validator"):
            self.assertNotIn(f"docker restart {name}", log)
        h = self.history()[-1]
        self.assertEqual((h["action"], h["by"], h["ok"]), ("watchdog", "watchdog", True))
        # Still empty a minute later (say the restart didn't help): no restart loop.
        self.assertEqual(nc.watchdog(self.T + 60), [])
        self.assertEqual(self.calls_log().count("docker restart pulse-grafana"), 1)
        # An hour later it tries again.
        self.assertEqual(len(nc.watchdog(self.T + 3601)), 1)

    def test_no_dns_restart_while_host_has_no_dns_either(self):
        self.write(self.host_resolv, "# dhcpcd: no lease yet\n")
        self.containers({"pulse-grafana": "# empty\n"}, beacon_started=self.T - 3600)
        self.assertEqual(nc.watchdog(self.T), [])
        self.assertNotIn("docker restart", self.calls_log())
        self.assertEqual(self.history(), [])

    # --- Prysm -------------------------------------------------------------------
    def test_prysm_restarted_after_ten_minutes_at_zero_peers(self):
        self.peers = (50, 0)
        self.assertEqual(nc.watchdog(self.T), [])            # starts counting
        self.assertEqual(nc.watchdog(self.T + 300), [])      # 5 min: not yet
        done = nc.watchdog(self.T + 600)
        self.assertEqual(len(done), 1); self.assertTrue(done[0][0])
        self.assertIn("Prysm stuck at 0 peers", done[0][1])
        self.assertIn("docker compose restart beacon", self.calls_log())
        # Still at 0 afterwards: no second restart within the hour.
        for m in range(11, 60):
            nc.watchdog(self.T + m * 60)
        self.assertEqual(self.calls_log().count("compose restart beacon"), 1)

    def test_prysm_peers_coming_back_resets_the_count(self):
        self.peers = (50, 0); nc.watchdog(self.T)
        self.peers = (50, 3); nc.watchdog(self.T + 300)
        self.peers = (50, 0); nc.watchdog(self.T + 400)
        self.assertEqual(nc.watchdog(self.T + 700), [])      # only 5 min since it dropped again
        self.assertNotIn("compose restart", self.calls_log())

    def test_prysm_left_alone_when_not_its_fault(self):
        cases = {
            "go-pulse has no peers either (network down)": dict(peers=(0, 0)),
            "go-pulse not answering": dict(peers=(None, 0)),
            "Prysm not answering": dict(peers=(50, None)),
            # Up 1 min at the start, so still under 10 min at the last check below.
            "Prysm only just started": dict(peers=(50, 0), started=self.T - 60, minutes=8),
            "Prysm container stopped": dict(peers=(50, 0), running=False),
            "node stopped on purpose": dict(peers=(50, 0), stopped=True),
        }
        for why, c in cases.items():
            with self.subTest(why):
                for f in ("watchdog.json", "stopped.json", "../calls.log"):
                    if os.path.exists(os.path.join(self.state, f)):
                        os.remove(os.path.join(self.state, f))
                if c.get("stopped"):
                    self.write(os.path.join(self.state, "stopped.json"), "{}")
                self.peers = c["peers"]
                self.containers({}, beacon_started=c.get("started", self.T - 3600),
                                beacon_running=c.get("running", True))
                for m in range(0, c.get("minutes", 30)):
                    nc.watchdog(self.T + m * 60)
                self.assertNotIn("compose restart", self.calls_log())

    def test_skips_while_an_action_holds_the_lock(self):
        self.peers = (50, 0)
        with nc.Lock():
            self.assertEqual(nc.main(["node-control.py", "watchdog"]), 0)
        self.assertFalse(os.path.exists(os.path.join(self.state, "watchdog.json")))


if __name__ == "__main__":
    unittest.main()
