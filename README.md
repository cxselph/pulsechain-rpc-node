# pulsechain-rpc-node

Run a **PulseChain mainnet full node** and use it as a **private JSON-RPC endpoint** for MetaMask, Internet Money, and other wallets.

This project packages the official PulseChain clients in Docker Compose with a single install script. No manual client builds, no complex config for the common case.

| Component | Role | Image |
|-----------|------|-------|
| [Go-Pulse](https://gitlab.com/pulsechaincom/go-pulse) | Execution layer (JSON-RPC / WebSocket) | `registry.gitlab.com/pulsechaincom/go-pulse:v3.3.0` |
| [Prysm-Pulse](https://gitlab.com/pulsechaincom/prysm-pulse) | Consensus layer (beacon chain) | `registry.gitlab.com/pulsechaincom/prysm-pulse/beacon-chain:v2.3.0` |

**Defaults:** mainnet · checkpoint sync · data under `/blockchain` · wallet RPC on the LAN (`0.0.0.0`) · Engine API and beacon HTTP/gRPC localhost-only · digest-pinned client tags (`./update.sh --latest` writes `:latest` into `.env`) · bind addresses and P2P ports via `.env` (so `git pull` does not wipe them)

---

## Quick start

**Requirements:** Linux (Ubuntu 22.04 / 24.04, Debian, or [Omarchy](https://omarchy.org); amd64 or arm64), `sudo`, outbound internet, and a large SSD mounted where `/blockchain` will live.

```bash
git clone https://github.com/DavidFeder/pulsechain-rpc-node.git
cd pulsechain-rpc-node
chmod +x install.sh
./install.sh
```

The installer will:

1. Install Docker Engine and the Compose plugin if they are missing (Ubuntu/Debian via Docker CE; Omarchy/Arch via `omarchy-pkg-add` or pacman)
2. Enable Docker to start on boot (needed so the node comes back after reboot; Omarchy otherwise only socket-activates Docker)
3. Create `/blockchain` (with `execution` / `consensus` subdirs) and generate a JWT secret if needed
4. Pull the official images and start both containers
5. Print your LAN IP and wallet connection settings

---

## Hardware recommendations

PulseChain includes Ethereum mainnet state through the fork block, so storage and memory needs are substantial.

| Resource | Recommended | Minimum |
|----------|-------------|---------|
| **RAM** | 32 GB or more | 16 GB (may swap under load) |
| **Storage** | 2 TB+ NVMe SSD | 1.5 TB+ fast SSD (full node; leave growth headroom) |
| **CPU** | 4+ modern cores | 4 cores |
| **Network** | Stable broadband, preferably unmetered | Required for sync and peers |

- Use an **SSD**. Mechanical drives are generally unsuitable for a reliable full node.
- Initial sync can take **hours to days**, depending on hardware and bandwidth. Checkpoint sync accelerates the beacon client significantly.
- This stack targets a **full node + private RPC**, not an archive node (archive deployments need many terabytes of disk).

If you need ready-to-run node hardware, you can find pre-built options at [validatorstore.com](https://validatorstore.com).

---

## Security notice

> **By default, wallet RPC ports are bound to all interfaces (`0.0.0.0`) and are reachable on your local network.**

| Port | Service |
|------|---------|
| **8545** | HTTP JSON-RPC (primary wallet endpoint) |
| **8546** | WebSocket RPC |
| **3500** | Beacon HTTP API (**localhost** by default) |
| **4000** | Beacon gRPC (**localhost** by default; not needed for MetaMask) |

**Intended use**

- Trusted home or lab network, behind a normal router firewall
- Private RPC for devices you control on that LAN

**Not intended for**

- Public internet exposure
- Untrusted or shared networks without additional controls

**Do not** port-forward **8545**, **8546**, **3500**, or **4000** to the public internet. This project is a **private RPC**, not a public endpoint. The Engine API on **8551** and the beacon HTTP/gRPC APIs are bound to localhost.

Checkpoint sync trusts [checkpoint.pulsechain.com](https://checkpoint.pulsechain.com) (same URL as the official PulseChain docs). That is a trusted third party for the initial beacon state. Prysm also recommends pairing it with a weak-subjectivity checkpoint if you want extra assurance against a long-range attack.

CORS / vhosts default to `*` so LAN web wallets can reach the node. A page you visit can also call that RPC if it can reach the LAN IP — keep this on a trusted network.

The installer warns if the host itself has a public IP and UFW is not active. That is the typical VPS misconfiguration (an unauthenticated public RPC). Home machines behind NAT are fine.

LAN binding is intentional so phones and other machines on the same network can use `http://YOUR_LAN_IP:8545`. To restrict access to the host only, set `HTTP_ADDR` / `WS_ADDR` in `.env` — see [Localhost-only mode](#localhost-only-mode).

---

## Omarchy Linux

[Omarchy](https://omarchy.org) is Arch-based and already ships Docker, Compose, and UFW on typical installs. `./install.sh` detects it even when `/etc/os-release` still says `ID=arch`.

What the installer does on Omarchy:

- Installs `docker`, `docker-compose`, `docker-buildx`, and `openssl` if missing, using `omarchy-pkg-add` when that command exists (otherwise `pacman -S --needed`). It does **not** run `pacman -Syu`, which Omarchy blocks in favor of `omarchy update`.
- Enables `docker.service` on boot. Omarchy’s default is `docker.socket` only; without a running daemon, `restart: unless-stopped` containers would not return after a reboot.
- Adds UFW rules for P2P (open) and wallet RPC (private ranges). Omarchy’s first-run firewall is deny-incoming, so those P2P rules are what allow inbound peers.

```bash
git clone https://github.com/DavidFeder/pulsechain-rpc-node.git
cd pulsechain-rpc-node
chmod +x *.sh
./install.sh
```

If Docker was just added to your user group, log out and back in (or reboot) before using `./status.sh` without sudo.

---

## Installation

### Prerequisites

- Linux host (Ubuntu 22.04 / 24.04, Debian, or [Omarchy](https://omarchy.org); **amd64 or arm64**). Vanilla Arch works with the same pacman path.
- `sudo` privileges
- Sufficient free space for `/blockchain`
- Outbound connectivity to pull images and sync with the network

### Install

```bash
git clone https://github.com/DavidFeder/pulsechain-rpc-node.git
cd pulsechain-rpc-node
chmod +x *.sh
./install.sh
```

### Sync status

```bash
./logs.sh
# or
./status.sh
```

- The **beacon** client typically advances quickly via [checkpoint sync](https://checkpoint.pulsechain.com).
- The **execution** client (Go-Pulse) generally takes longer to fully sync.
- The RPC may respond before the node is fully synced. Wait until both clients are healthy before relying on the endpoint for important transactions.

### Discover your LAN IP

Printed by the installer and by `./status.sh` (source address of the default route). Prefer that over `hostname -I`, which often prints Docker's `172.17.0.1` (`docker0`) first and will not work from a phone.

---

## Wallet configuration

### MetaMask

1. Open MetaMask → **Networks** → **Add network** → **Add a network manually**
2. Use the following parameters:

| Field | Value |
|-------|--------|
| Network Name | PulseChain |
| New RPC URL | `http://YOUR_LAN_IP:8545` |
| Chain ID | `369` |
| Currency Symbol | `PLS` |
| Block explorer URL | `https://scan.pulsechain.com` |

**Example:** if the node host is `192.168.1.50`, set the RPC URL to `http://192.168.1.50:8545`.

### Internet Money and other wallets

Use the same network parameters:

| Setting | Value |
|---------|--------|
| RPC URL | `http://YOUR_LAN_IP:8545` |
| Chain ID | `369` |
| Symbol | `PLS` |
| Explorer | `https://scan.pulsechain.com` |

Mobile wallets must reach the node over the **same LAN** (or a VPN you configure yourself; VPN setup is out of scope for this guide).

---

## Operations

Run the following from the project directory:

| Action | Command |
|--------|---------|
| Sync, peers, and disk | `./status.sh` |
| Follow logs (both services) | `./logs.sh` |
| Follow Go-Pulse logs | `./logs.sh geth` |
| Follow beacon logs | `./logs.sh beacon` |
| Stop | `./stop.sh` |
| Start | `./start.sh` |
| Recreate from compose (applies flag/.env changes and bounces containers) | `./restart.sh` |
| Update pinned images and recreate | `./update.sh` |
| Float on upstream `:latest` images (persists to `.env`) | `./update.sh --latest` |

Equivalent Docker Compose commands:

```bash
docker compose logs -f
docker compose down
docker compose up -d
docker compose pull && docker compose up -d
```

Chain data is stored under **`/blockchain`** and is retained when containers are stopped.

---

## Optional: monitoring (Grafana + Prometheus)

Graphs, history and email alerts for the node, all running on the node host and bound to `127.0.0.1` (no new firewall rules, nothing exposed to the LAN).

| Piece | Role |
|---|---|
| Prometheus (`127.0.0.1:9090`) | Scrapes go-pulse, Prysm and node_exporter every 15 s; keeps 30 days (`$DATA_DIR/monitoring/prometheus`) |
| node_exporter (`127.0.0.1:9100`) | Host CPU, memory, disk, network |
| `pulse-node-metrics` timer | Every 30 s, a small read-only helper asks go-pulse and Prysm what `status.sh` asks (sync, blocks, peers, `el_offline`) and writes it for node_exporter. It runs as an unprivileged systemd `DynamicUser` that can only talk to localhost. |
| Grafana (`127.0.0.1:3000/grafana/`) | Dashboards ("PulseChain node overview", "Node Exporter Full") and alerts by email |

**Install** (after the node is running):

```bash
./monitoring/install.sh          # first run creates monitoring/.env, then stops
nano monitoring/.env             # SMTP server/user/password, sender, ALERT_EMAIL_TO
./monitoring/install.sh          # installs the helper, starts the stack, asks for a Grafana password
```

**Open Grafana** from your computer through an SSH tunnel: `ssh -L 3000:127.0.0.1:3000 <user>@<node>`, then http://localhost:3000/grafana/ (user `admin`). Send a test email under Alerting → Contact points → email → Test.

**Alerts** (email, repeated every 12 h while active): go-pulse or Prysm not answering, a scrape target down, the status helper stopped, initial sync stalled for 1 h, chain head stopped for 10 min, beacon more than 50 slots behind, fewer than 5 peers, beacon reports go-pulse offline after sync, a disk over 85%, chain disk full within 30 days at the current rate, and a client restarting repeatedly.

**Password recovery.** Lost the Grafana password? Run `./monitoring/reset-grafana-password.sh` on the node. No old password is needed. Lost the SMTP password? Create a new one with your provider, update `monitoring/.env`, then run `./monitoring/restart.sh`.

| Action | Command |
|---|---|
| Status (containers, helper, targets) | `./monitoring/status.sh` |
| Logs | `./monitoring/logs.sh [grafana\|prometheus\|node-exporter]` |
| Apply `.env` changes | `./monitoring/restart.sh` |
| Stop / start | `./monitoring/stop.sh`, `./monitoring/start.sh` |

`monitoring/.env` holds the SMTP password: it is gitignored and kept at mode 600. Grafana makes no outbound calls apart from email (usage reporting, update checks, news and plugin downloads are all disabled).

---

## Optional: HTTPS front end (`https://<your-host>`)

One hostname for everything, served by Caddy on the node host:

| Request | Goes to |
|---|---|
| `POST https://<host>` (and CORS preflight) | go-pulse JSON-RPC — use **`https://<host>`** as the wallet RPC URL |
| WebSocket `wss://<host>` | go-pulse WebSocket |
| `https://<host>/grafana/` | Grafana (if the monitoring stack is installed) |
| anything else in a browser | a small landing page with the wallet settings |
| `http://<host>` | redirects to https |

You need a DNS record for the hostname pointing at the node (router / local DNS), and a certificate for **exactly** that name from a CA your devices trust. For a local-only name like `rpc.home`, that's your own private CA. Public CAs can't issue for it.

```bash
# copy cert + key to the node first (e.g. scp cert.pem key.pem user@node:~/)
./proxy/install.sh --host rpc.home --cert ~/cert.pem --key ~/key.pem
rm ~/key.pem                    # the installer keeps its own root-only copy
./proxy/status.sh               # certificate, firewall, and a live check of every route
```

What the installer does:
- **Checks the certificate:** it's for the hostname, the key matches, and it isn't expired.
- **Installs it** to `/etc/pulse-proxy/tls`, with the key readable by root only.
- **Opens UFW 443 and 80** to `LAN_ALLOW_FROM` only.
- **Starts Caddy**, which runs read-only with every capability dropped except binding low ports, and with its admin API off.
- **Moves Grafana** to `https://<host>/grafana/` with Secure cookies, if monitoring is installed.
- **Tests every route.**

To renew the certificate, run `./proxy/install.sh --cert new.pem --key new-key.pem`.

There's no HSTS header on purpose. With a private CA it would lock out any device that doesn't trust the CA yet. Don't port-forward 443 or 80 on the router: this stays a private endpoint.

---

## Optional: control page (`https://<your-host>/`)

A phone-friendly page, served through the HTTPS front end, that shows node health and offers a fixed set of actions:

- **Status:** a green / yellow / red banner; sync progress (with an ETA if monitoring is installed); peers; beacon; disk; Debian updates; go-pulse / Prysm versions; the fork commit; and whether `main` has updates (with the commit list and any image-pin changes). It refreshes on its own.
- **Actions** (each behind a confirm screen, one at a time, all logged with output):
  - Check for updates
  - Apply update
  - Roll back
  - Restart node / go-pulse / Prysm

**How it stays safe.** The page runs in a container with no Docker socket, a read-only filesystem, no capabilities, and no access to the repo. Pressing a button only drops a small request file in `/var/lib/node-control/requests`. Only the page's user can write there, and only the repo owner can read it. A systemd path unit then runs [`control/node-control.py`](control/node-control.py) **as the repo owner (not root)**. It accepts only the six actions above and rejects anything else.

**Apply update** fast-forwards to what's already merged on `origin/main`, never anything else. It refuses if the checkout has local changes or isn't on `main`. It then restarts only what changed:

| What changed | What runs |
|---|---|
| `docker-compose.yml` / `common.sh` | `./update.sh` (pinned images) |
| `monitoring/` | the monitoring stack |
| `proxy/` | the HTTPS front end |
| `control/` | the page itself |

Changes that need `sudo` (the monitoring helper, the control systemd units) are reported as a manual SSH step. **Roll back** returns to the commit before the last update the same way.

**Sign-in.**
- One password (scrypt hash, base64-encoded in `control/.env`, mode 600).
- The session cookie is `__Host-`, Secure, HttpOnly and SameSite=Strict, with CSRF tokens on every form.
- After 5 failed logins per IP (20 in total) within 15 minutes, sign-in is refused until the window passes.
- The page sends a strict CSP (no inline scripts or styles).

```bash
./control/install.sh          # as the repo owner, after ./proxy/install.sh; asks for a password
./control/status.sh           # container, helper units, last actions
./control/set-password.sh     # forgot the password: sets a new one and signs every device out
```

If the control page isn't running, `https://<host>/` falls back to the static landing page. The wallet RPC on the same address is unaffected either way.

---

## Dependency updates

Nothing upstream reaches the node without review:

- **Client images** are pinned by tag *and* digest in `docker-compose.yml` and `common.sh` (`tests/test_image_pins.sh` keeps them in sync with the registry). A weekly workflow (`.github/workflows/upstream-releases.yml`) runs `tests/check_upstream_releases.sh` and opens an issue when PulseChain publishes a newer release. Bump the pin in a PR after reading the release notes, preferably once the release has been public for about 14 days (sooner for a security fix).
- **Avoid `./update.sh --latest`** on a node you rely on. It floats on unpinned `:latest` images, so whatever is published next is what you run.
- **Docker Engine** comes from Docker's signed apt repo. `install.sh` checks the signing key's fingerprint (`DOCKER_GPG_FINGERPRINT` in `common.sh`) before trusting it, and stops if it doesn't match.
- **GitHub Actions** are pinned by commit SHA. Dependabot proposes minor/patch updates weekly with a 14-day cooldown and never merges them itself.
- **Caddy** (HTTPS front end) is pinned by tag + digest in `proxy/docker-compose.yml`; `tests/test_proxy.sh` checks it against Docker Hub, and Dependabot covers it with the same policy.
- **Control page:** base image pinned by digest in `control/Dockerfile`. Python packages are locked with hashes in `control/requirements.txt` (`pip install --require-hashes`; regenerate it with `pip-compile --generate-hashes` from `requirements.in`). Dependabot covers both.
- **Monitoring images** (Prometheus, node_exporter, Grafana) are pinned by tag + digest in `monitoring/docker-compose.yml` and covered by the same Dependabot policy. `tests/test_monitoring.sh` checks each digest against Docker Hub.

Don't switch any of these to floating tags or skip a verification step to get past an error. Fix the pin instead.

---

## Localhost-only mode

By default, **wallet** RPC binds to `0.0.0.0` (all interfaces). The Engine API (`--authrpc.addr=127.0.0.1`, port 8551) and beacon HTTP/gRPC (`BEACON_HTTP_HOST` / `BEACON_GRPC_HOST`, default `127.0.0.1`) are already host-only.

To accept wallet RPC connections **only on the host**, set these in `.env` (do not edit `docker-compose.yml` — a `git pull` would overwrite compose edits):

```bash
HTTP_ADDR=127.0.0.1
WS_ADDR=127.0.0.1
```

Then apply:

```bash
./restart.sh
```

Use `http://127.0.0.1:8545` in wallets on **that machine only**.

### LAN beacon API (optional)

Beacon REST/gRPC are not required for MetaMask. Prysm-Pulse still uses `--grpc-gateway-host` / `--rpc-host` (not `--http-host`). To expose them on the LAN, set in `.env`:

```bash
BEACON_HTTP_HOST=0.0.0.0
BEACON_GRPC_HOST=0.0.0.0
```

Then run `./restart.sh`. Keep those ports firewalled to your LAN; never port-forward them.

---

## Network ports

| Port | Protocol | Purpose | Default bind |
|------|----------|---------|--------------|
| 8545 | TCP | HTTP JSON-RPC (wallets) | `0.0.0.0` (LAN; `HTTP_ADDR` / `HTTP_PORT`) |
| 8546 | TCP | WebSocket RPC | `0.0.0.0` (LAN; `WS_ADDR` / `WS_PORT`) |
| 3500 | TCP | Beacon REST API | `127.0.0.1` (localhost; override with `BEACON_HTTP_HOST`) |
| 4000 | TCP | Beacon gRPC | `127.0.0.1` (localhost; override with `BEACON_GRPC_HOST`) |
| 8551 | TCP | Engine API (JWT; geth ↔ beacon) | `127.0.0.1` (localhost only) |
| 6060 | TCP | go-pulse Prometheus metrics (`/debug/metrics/prometheus`) | `127.0.0.1` (localhost only; `GETH_METRICS_PORT`) |
| 8080 | TCP | Prysm Prometheus metrics (`/metrics`) | `127.0.0.1` (localhost only; `BEACON_METRICS_PORT`) |
| 30303 | TCP/UDP | Execution P2P | Host (`GETH_P2P_PORT`) |
| 13000 | TCP | Beacon P2P | Host (`BEACON_P2P_TCP_PORT`) |
| 12000 | UDP | Beacon P2P | Host (`BEACON_P2P_UDP_PORT`) |

**Do not** forward RPC/API ports 8545, 8546, 3500, or 4000 to the public internet.

---

## Opening P2P ports (strongly recommended)

Your node can already make **outbound** connections. That is not enough if you want a healthy, well-connected node.

To properly participate in the network you should also accept **inbound** peers. Nodes that only make outbound connections put more load on the network and usually have worse peer counts and slower sync.

**Open these ports for inbound traffic** (defaults; keep the router in sync if you change `.env`):

| Port | Protocol | Purpose | `.env` |
|------|----------|---------|--------|
| 30303 | TCP + UDP | Go-Pulse (execution) | `GETH_P2P_PORT` |
| 13000 | TCP | Beacon P2P | `BEACON_P2P_TCP_PORT` |
| 12000 | UDP | Beacon P2P | `BEACON_P2P_UDP_PORT` |

### 1. Firewall on the node (UFW)

The install script already adds the rules if UFW is present. You can also add them manually:

```bash
sudo ufw allow 30303/tcp
sudo ufw allow 30303/udp
sudo ufw allow 13000/tcp
sudo ufw allow 12000/udp
```

`./install.sh` uses the P2P ports from `.env` when it adds these rules.

### 2. Port forwarding on your router (required for inbound peers)

This is the part most people skip — and it’s the most important.

You must log into your router and forward the ports above to the local IP of the machine running the node.

- Log into your router (usually `192.168.0.1` or `192.168.1.1`)
- Find **Port Forwarding / Virtual Server / NAT**
- Forward external ports 30303, 13000, and 12000 to the same ports on your node’s local IP

**Every router is different.**  
Look up your exact make and model, or ask an AI with the model name for step-by-step instructions. We cannot give universal router instructions.

If you do not open these ports on your router, your node will mostly only connect outward and will contribute less to the network.

Opening inbound P2P is one of the highest-impact things you can do for both your own node performance and the health of PulseChain.

---

## Recommended firewall (UFW)

If you use UFW, here are sensible rules for a home node:

```bash
# Allow SSH (adjust if you use a different port)
sudo ufw allow OpenSSH

# Allow P2P (helps with peer count)
sudo ufw allow 30303/tcp
sudo ufw allow 30303/udp
sudo ufw allow 13000/tcp
sudo ufw allow 12000/udp

# Allow RPC only from your local network (edit the subnet!)
# Common home subnets: 192.168.0.0/16 or 192.168.1.0/24
sudo ufw allow from 192.168.0.0/16 to any port 8545 proto tcp comment 'Geth HTTP RPC - LAN only'
sudo ufw allow from 192.168.0.0/16 to any port 8546 proto tcp comment 'Geth WS RPC - LAN only'
sudo ufw allow from 192.168.0.0/16 to any port 3500 proto tcp comment 'Beacon HTTP API - LAN only'
sudo ufw allow from 192.168.0.0/16 to any port 4000 proto tcp comment 'Beacon gRPC - LAN only'

sudo ufw enable
sudo ufw status numbered
```

Replace `192.168.0.0/16` with your actual LAN range. Never open the RPC ports to `0.0.0.0/0` or the public internet. These examples are IPv4; if the host has global IPv6, add matching `from <your-ula>` rules or disable IPv6 on the node.

On a VPS or cloud VM, `10.0.0.0/8` (and often `172.16.0.0/12`) is the **VPC**, not a home Wi-Fi. Tighten `from` to your office/VPN prefix instead of the whole RFC1918 range.

---

## Configuration summary

| Setting | Value |
|---------|--------|
| Network | PulseChain mainnet (`--pulsechain`), chain ID `369` |
| Host data root | `/blockchain` (override with `DATA_DIR` in `.env`) |
| Execution datadir | `$DATA_DIR/execution` |
| Consensus datadir | `$DATA_DIR/consensus` |
| JWT secret | `$DATA_DIR/jwt.hex` (mode `600`) |
| Execution image | `go-pulse:v3.3.0` digest-pinned (override with `GETH_IMAGE` or `./update.sh --latest`) |
| Beacon image | `beacon-chain:v2.3.0` digest-pinned (override with `BEACON_IMAGE` or `./update.sh --latest`) |
| Wallet RPC bind | `0.0.0.0` (`HTTP_ADDR` / `WS_ADDR`; set `127.0.0.1` for localhost-only) |
| Beacon HTTP / gRPC | `127.0.0.1` (`BEACON_HTTP_HOST` / `BEACON_GRPC_HOST`) |
| P2P ports | `30303` / `13000` / `12000` (`GETH_P2P_PORT`, `BEACON_P2P_TCP_PORT`, `BEACON_P2P_UDP_PORT`) |
| Geth IPC | disabled (`--ipcdisable`; admin APIs are not on the host filesystem) |
| Geth cache | `1024` MB (`GETH_CACHE`) |
| File descriptors | `nofile` 65535 (container ulimit) |
| Checkpoint sync | `https://checkpoint.pulsechain.com` (trusted third party; same as official docs) |
| Metrics | go-pulse `127.0.0.1:6060`, Prysm `127.0.0.1:8080` (Prometheus format, localhost only) |
| Docker safeguards | `install.sh` adds a systemd drop-in (`RequiresMountsFor=$DATA_DIR`, `TimeoutStopSec=390`) and `"shutdown-timeout": 300` in `/etc/docker/daemon.json` (only if that file doesn't exist yet), so a host shutdown gives go-pulse time to close its database |
| Restart policy | `unless-stopped` |
| Stop grace period | `5m` |
| Geth healthcheck | `geth attach --exec eth.chainId` against local HTTP RPC (beacon does not wait on it) |
| Container logs | json-file, 50 MB × 5 files |
| Networking | `host` (aligned with official examples; simplifies P2P) |

Optional variables (`DATA_DIR`, bind addresses, ports, image pins) are documented in `.env.example` and are read by both Compose and the helper scripts. Changing `DATA_DIR` after the first sync starts a new empty node at the new path; the old chain data stays where it was.

---

## Troubleshooting

| Issue | Suggested action |
|-------|------------------|
| Docker permission denied | Log out and back in after install (docker group membership), or prefix commands with `sudo`. On Omarchy this is common until the session picks up the `docker` group. |
| Installer asks about Docker CE | On Ubuntu/Debian, replacing `docker.io` / distro Compose can stop existing containers. Confirm only if you want Docker CE, or install Docker yourself and re-run. Unattended: `PULSE_ALLOW_DOCKER_CE=1`. |
| `address already in use` / crash loop | Another node is using ports 8545, 8546, 3500, 4000, or 8551. Stop the other process or change ports in `.env` |
| Beacon cannot find execution client | Confirm both containers are running and that `/blockchain/jwt.hex` exists and is shared by both |
| JWT / `401 Unauthorized` to execution | Ensure only one execution client is on port 8551 and both services use the same `/blockchain/jwt.hex`. The file must be 64 hex characters with **no newline**. Keep the host clock in sync (NTP / `timedatectl`); JWT `iat` skew also returns 401. |
| Wallet cannot connect | Verify LAN IP from `./status.sh` (not `hostname -I` / docker0), same network, host firewall rules; test `curl` against `127.0.0.1:8545` on the node. If you set `HTTP_ADDR=127.0.0.1`, only wallets on this machine work. `./restart.sh` after `.env` or compose edits (it recreates containers). |
| `./restart.sh` did nothing (old versions) | Current `restart.sh` uses `docker compose up -d --force-recreate`. Upgrade the scripts if an older copy only ran `up -d`. |
| Disk space pressure | Full nodes grow over time — monitor free space and use a large SSD |
| Slow sync | Prefer NVMe storage, adequate RAM, and open P2P ports where practical. On 16 GB hosts, try `GETH_CACHE=512` in `.env` if the machine swaps. |

**Health checks** (run on the node host):

```bash
./status.sh
```

`status.sh` reports container state, `eth_syncing` / block / peers, beacon sync, disk free, and the wallet RPC URL.

If `eth_syncing` returns `false`, the execution client reports that it is synced. Wait for the beacon section to report synced as well before relying on the endpoint.

---

## Repository layout

```
pulsechain-rpc-node/
├── README.md
├── LICENSE
├── docker-compose.yml    # Go-Pulse + Prysm-Pulse
├── .env.example          # DATA_DIR, ports, image pins
├── common.sh             # Shared env + docker compose helpers
├── install.sh            # One-command setup
├── status.sh             # Sync, peers, disk
├── start.sh
├── stop.sh
├── restart.sh            # Recreate from compose (applies edits)
├── logs.sh
├── update.sh             # Pull pinned images; --latest to float
├── tests/
│   ├── test_common.sh
│   ├── test_beacon_flags.sh
│   ├── test_image_pins.sh
│   ├── check_upstream_releases.sh  # weekly: newer PulseChain releases?
│   ├── test_monitoring.sh
│   ├── test_proxy.sh
│   └── test_control.sh
├── monitoring/               # optional Grafana + Prometheus stack (see above)
├── proxy/                    # optional HTTPS front end (Caddy)
├── control/                  # optional control page + node-control helper
```

---

## Credits

| Resource | Link |
|----------|------|
| Go-Pulse (execution) | [gitlab.com/pulsechaincom/go-pulse](https://gitlab.com/pulsechaincom/go-pulse) |
| Prysm-Pulse (consensus) | [gitlab.com/pulsechaincom/prysm-pulse](https://gitlab.com/pulsechaincom/prysm-pulse) |
| Official mainnet documentation | [gitlab.com/pulsechaincom/pulsechain-mainnet](https://gitlab.com/pulsechaincom/pulsechain-mainnet) |
| Checkpoint sync | [checkpoint.pulsechain.com](https://checkpoint.pulsechain.com) |
| Block explorer | [scan.pulsechain.com](https://scan.pulsechain.com) |

This project is a convenience wrapper around the **official PulseChain Docker images**. It is an independent community project and is not affiliated with PulseChain Core unless otherwise stated.

---

## License

[MIT](LICENSE)
