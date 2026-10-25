#!/usr/bin/env python3
"""Write PulseChain node status as Prometheus metrics for node_exporter's textfile collector.

Read-only: asks go-pulse (JSON-RPC) and Prysm (beacon REST) the same questions
status.sh does, on 127.0.0.1 only. Run every 30 s by pulse-node-metrics.timer.
Standard library only.

It also times how long the node takes to get back in sync after each boot
(resync.json in the state directory). Grafana turns that into one report
email per reboot; see the pulse-resync-* alert rules.
"""
import json
import os
import sys
import tempfile
import time
import urllib.request

RPC_URL = os.environ.get("PULSE_RPC_URL", "http://127.0.0.1:8545")
BEACON_URL = os.environ.get("PULSE_BEACON_URL", "http://127.0.0.1:3500")
OUT_DIR = os.environ.get("STATE_DIRECTORY", "/var/lib/pulse-node-metrics")
# Present only while the validator is switched on (validator/enable.sh).
VALIDATOR_ENABLED = os.environ.get("PULSE_VALIDATOR_ENABLED", "/blockchain/validator/ENABLED")
OUT_FILE = "pulse_node.prom"
RESYNC_FILE = "resync.json"
TIMEOUT = 5

# Resync after a reboot: the target (keep in step with the pulse-resync-slow
# alert rule), how long the report series stays up for Grafana to email it, and
# how far behind the newest go-pulse block may be to count as synced.
RESYNC_TARGET = 900
REPORT_FOR = 1800
HEAD_MAX_AGE = 60

# eth_syncing fields that only grow while a snap sync makes progress.
SNAP_FIELDS = [
    "syncedAccounts",
    "syncedStorage",
    "syncedBytecodes",
    "healedTrienodes",
    "healedBytecodes",
]


def rpc(method, params=()):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}).encode()
    req = urllib.request.Request(
        RPC_URL, data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        data = json.load(resp)
    if "error" in data:
        raise RuntimeError(data["error"])
    return data["result"]


def beacon(path):
    with urllib.request.urlopen(BEACON_URL + path, timeout=TIMEOUT) as resp:
        return json.load(resp)["data"]


def num(value):
    """Hex quantity ("0x1a"), decimal string, bool or int -> int."""
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value, 16) if value.startswith("0x") else int(value)
    raise ValueError(f"not a number: {value!r}")


def collect():
    metrics = {}  # name -> (help, value)

    def put(name, help_text, value):
        metrics[name] = (help_text, value)

    # --- Execution layer (go-pulse) ---
    try:
        syncing = rpc("eth_syncing")
        peers = num(rpc("net_peerCount"))
        if syncing is False:
            current = highest = num(rpc("eth_blockNumber"))
            progress = current
            snap = {f: 0 for f in SNAP_FIELDS}
        else:
            current = num(syncing.get("currentBlock", 0))
            highest = num(syncing.get("highestBlock", 0))
            snap = {f: num(syncing.get(f, 0)) for f in SNAP_FIELDS}
            progress = current + sum(snap.values())
        put("pulse_el_up", "1 if go-pulse JSON-RPC answered", 1)
        put("pulse_el_syncing", "1 while go-pulse reports eth_syncing", int(syncing is not False))
        put("pulse_el_current_block", "go-pulse current block (eth_syncing / eth_blockNumber)", current)
        put("pulse_el_highest_block", "Highest block go-pulse knows of", highest)
        put("pulse_el_peers", "go-pulse peer count (net_peerCount)", peers)
        put(
            "pulse_el_sync_progress",
            "Sum of block and snap-sync counters; grows while the sync makes any progress",
            progress,
        )
        for field, value in snap.items():
            snake = "".join("_" + c.lower() if c.isupper() else c for c in field)
            put(f"pulse_el_snap_{snake}", f"eth_syncing {field}", value)
        try:
            head = rpc("eth_getBlockByNumber", ["latest", False])
            put(
                "pulse_el_head_age_seconds",
                "Seconds since the newest go-pulse block was made",
                max(0, int(time.time()) - num(head["timestamp"])),
            )
        except Exception as exc:  # noqa: BLE001
            print(f"go-pulse latest block: {exc}", file=sys.stderr)
    except Exception as exc:  # noqa: BLE001 - any failure means "down"
        put("pulse_el_up", "1 if go-pulse JSON-RPC answered", 0)
        print(f"go-pulse RPC: {exc}", file=sys.stderr)

    # --- Consensus layer (Prysm) ---
    try:
        sync = beacon("/eth/v1/node/syncing")
        put("pulse_cl_up", "1 if the Prysm beacon API answered", 1)
        put("pulse_cl_syncing", "1 while the beacon node is syncing", num(sync.get("is_syncing", False)))
        put(
            "pulse_cl_el_offline",
            "1 while the beacon node reports the execution client offline",
            num(sync.get("el_offline", False)),
        )
        put("pulse_cl_optimistic", "1 while the beacon head is optimistic", num(sync.get("is_optimistic", False)))
        put("pulse_cl_head_slot", "Beacon head slot", num(sync.get("head_slot", 0)))
        put("pulse_cl_sync_distance", "Slots behind the network head", num(sync.get("sync_distance", 0)))
        try:
            peers = beacon("/eth/v1/node/peer_count")
            put("pulse_cl_peers", "Beacon connected peers", num(peers.get("connected", 0)))
        except Exception as exc:  # noqa: BLE001
            print(f"beacon peer_count: {exc}", file=sys.stderr)
    except Exception as exc:  # noqa: BLE001
        put("pulse_cl_up", "1 if the Prysm beacon API answered", 0)
        print(f"beacon API: {exc}", file=sys.stderr)

    # Gates the validator alerts, so a switched-off validator raises nothing.
    put("pulse_validator_enabled", "1 while the validator is switched on (validator/enable.sh)",
        int(os.path.exists(VALIDATOR_ENABLED)))
    put("pulse_metrics_last_run_timestamp_seconds", "When this helper last ran", int(time.time()))
    return metrics


def boot_time():
    """Wall-clock time this machine booted. PULSE_BOOT_TIME overrides it (tests)."""
    if "PULSE_BOOT_TIME" in os.environ:
        return int(os.environ["PULSE_BOOT_TIME"])
    clock = getattr(time, "CLOCK_BOOTTIME", time.CLOCK_MONOTONIC)
    return int(time.time() - time.clock_gettime(clock))


def metric(metrics, name):
    return metrics.get(name, (None, None))[1]


def clients_up(metrics):
    return metric(metrics, "pulse_el_up") == 1 and metric(metrics, "pulse_cl_up") == 1


def node_synced(metrics):
    """Both clients answering and caught up with the network head."""
    head_age = metric(metrics, "pulse_el_head_age_seconds")
    distance = metric(metrics, "pulse_cl_sync_distance")
    return (
        clients_up(metrics)
        and metric(metrics, "pulse_el_syncing") == 0
        and metric(metrics, "pulse_cl_syncing") == 0
        and distance is not None
        and distance <= 2
        and head_age is not None
        and head_age <= HEAD_MAX_AGE
    )


def clock(ts):
    return time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(ts))


def span(seconds):
    minutes, seconds = divmod(int(seconds), 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes}m {seconds}s" if hours else f"{minutes}m {seconds}s"


def track_resync(metrics, now, boot, path):
    """Record boot -> clients up -> synced for this boot and add resync metrics.

    resync.json survives reboots. A boot time that differs from the stored one
    by over a minute is a new boot. The very first run after install has no
    previous boot to compare with, so that boot isn't reported.
    """
    try:
        with open(path) as fh:
            state = json.load(fh)
    except (OSError, ValueError):
        state = None
    if state is None:
        state = {"boot": boot, "tracked": False}
    elif abs(state.get("boot", 0) - boot) > 60:
        # last_up: the last time the previous boot saw both clients answering.
        state = {"boot": boot, "tracked": True, "down": state.get("last_up")}

    if clients_up(metrics):
        state["last_up"] = now
        state.setdefault("up", now)
    if node_synced(metrics):
        state.setdefault("synced", now)

    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".resync.", suffix=".tmp")
    with os.fdopen(fd, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, path)

    def put(name, help_text, val):
        metrics[name] = (help_text, val)

    if not state["tracked"]:
        put("pulse_resync_pending", "1 from boot until the node is back in sync", 0)
        return
    boot, synced, down = state["boot"], state.get("synced"), state.get("down")
    put("pulse_resync_pending", "1 from boot until the node is back in sync", int(synced is None))
    put("pulse_resync_boot_timestamp_seconds", "When the machine last booted", boot)
    if synced is None:
        put("pulse_resync_elapsed_seconds", "Seconds since boot while not yet back in sync", now - boot)
        return
    put("pulse_resync_seconds", "Boot to back in sync, last reboot", synced - boot)
    if down is not None:
        put("pulse_resync_outage_seconds", "Clients last up before the reboot to back in sync", synced - down)
    if now - synced < REPORT_FOR:
        target = f"{RESYNC_TARGET // 60} min target"
        labels = {
            "booted": clock(boot),
            "up": clock(state["up"]) if "up" in state else "unknown",
            "synced": clock(synced),
            "took": span(synced - boot),
            "verdict": ("within the " if synced - boot <= RESYNC_TARGET else "OVER the ") + target,
            "down": clock(down) if down is not None else "unknown",
            "outage": span(synced - down) if down is not None else "unknown",
        }
        name = "pulse_resync_report{" + ",".join(f'{k}="{v}"' for k, v in labels.items()) + "}"
        put(name, "Present for 30 min after a reboot's resync, so Grafana emails the report", synced - boot)


def render(metrics):
    lines = []
    for name, (help_text, value) in metrics.items():
        base = name.split("{")[0]
        lines.append(f"# HELP {base} {help_text}")
        lines.append(f"# TYPE {base} gauge")
        lines.append(f"{name} {value}")
    return "\n".join(lines) + "\n"


def main():
    metrics = collect()
    track_resync(metrics, int(time.time()), boot_time(), os.path.join(OUT_DIR, RESYNC_FILE))
    text = render(metrics)
    # Atomic replace, so node_exporter never reads a half-written file.
    fd, tmp = tempfile.mkstemp(dir=OUT_DIR, prefix=".pulse_node.", suffix=".tmp")
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, os.path.join(OUT_DIR, OUT_FILE))


if __name__ == "__main__":
    main()
