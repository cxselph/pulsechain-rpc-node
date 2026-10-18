"""node-logs helper with a fake docker that prints lines, dies, and is followed again."""
import importlib.util
import os
import shutil
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("node_logs", os.path.join(HERE, "..", "node-logs.py"))
nl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nl)


class NodeLogsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.bin = os.path.join(self.tmp, "bin"); os.makedirs(self.bin)
        self.count = os.path.join(self.tmp, "runs")
        # Fake `docker logs -f --tail N name`: prints 3 lines (one with ANSI colour), then exits.
        with open(os.path.join(self.bin, "docker"), "w") as fh:
            fh.write(f'#!/bin/sh\necho x >> "{self.count}"\n'
                     'printf "INFO first %s\\n" "$5"\nprintf "\\033[33mWARN coloured\\033[0m\\n"\n'
                     'printf "%s\\n" "$(head -c 3000 /dev/zero | tr "\\0" a)"\nexit 0\n')
        os.chmod(os.path.join(self.bin, "docker"), 0o755)
        self.old_path = os.environ["PATH"]
        os.environ["PATH"] = self.bin + os.pathsep + self.old_path
        nl.LIVE_DIR = os.path.join(self.tmp, "live"); os.makedirs(nl.LIVE_DIR)

    def tearDown(self):
        os.environ["PATH"] = self.old_path
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_follow_write_and_restart(self):
        f = nl.Follower("pulse-geth")
        stop = threading.Event()
        t = threading.Thread(target=f.follow, args=(stop,), daemon=True)
        t.start()
        time.sleep(4.5)  # first run, 3 s pause, second run
        stop.set()
        f.write()
        with open(os.path.join(nl.LIVE_DIR, "pulse-geth.log")) as fh:
            head, *lines = fh.read().splitlines()
        with open(self.count) as fh:
            runs = len(fh.read().split())
        self.assertGreaterEqual(runs, 2, "follower restarts after docker logs exits")
        self.assertEqual(head, f"#seq {len(lines)}")
        self.assertEqual(lines[0], "INFO first pulse-geth")
        self.assertIn("WARN coloured", lines)                    # ANSI stripped
        self.assertTrue(all(len(l) <= nl.MAX_LINE_CHARS for l in lines))
        self.assertEqual(oct(os.stat(os.path.join(nl.LIVE_DIR, "pulse-geth.log")).st_mode & 0o777), "0o644")

    def test_cap_and_dirty_flag(self):
        f = nl.Follower("pulse-beacon")
        for i in range(nl.MAX_LINES + 50):
            f.add(f"l{i}")
        f.write()
        path = os.path.join(nl.LIVE_DIR, "pulse-beacon.log")
        with open(path) as fh:
            head, *lines = fh.read().splitlines()
        self.assertEqual(head, f"#seq {nl.MAX_LINES + 50}")
        self.assertEqual(len(lines), nl.MAX_LINES); self.assertEqual(lines[0], "l50")
        mtime = os.path.getmtime(path)
        time.sleep(0.05); f.write()  # nothing new -> file untouched
        self.assertEqual(os.path.getmtime(path), mtime)


if __name__ == "__main__":
    unittest.main()
