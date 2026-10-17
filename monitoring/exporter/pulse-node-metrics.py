#!/usr/bin/env python3
"""Write PulseChain node status as Prometheus metrics for node_exporter's textfile collector.

Read-only: asks go-pulse (JSON-RPC) and Prysm (beacon REST) the same questions
status.sh does, on 127.0.0.1 only. Run every 30 s by pulse-node-metrics.timer.
Standard library only.
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
OUT_FILE = "pulse_node.prom"
TIMEOUT = 5

# eth_syncing fields that only grow while a snap sync makes progress.
SNAP_FIELDS = [
    "syncedAccounts",
    "syncedStorage",
    "syncedBytecodes",
    "healedTrienodes",
    "healedBytecodes",
]


def rpc(method):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": []}).encode()
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

    put("pulse_metrics_last_run_timestamp_seconds", "When this helper last ran", int(time.time()))
    return metrics


def render(metrics):
    lines = []
    for name, (help_text, value) in metrics.items():
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} gauge")
        lines.append(f"{name} {value}")
    return "\n".join(lines) + "\n"


def main():
    text = render(collect())
    # Atomic replace, so node_exporter never reads a half-written file.
    fd, tmp = tempfile.mkstemp(dir=OUT_DIR, prefix=".pulse_node.", suffix=".tmp")
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, os.path.join(OUT_DIR, OUT_FILE))


if __name__ == "__main__":
    main()
