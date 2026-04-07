# TAK Server — Hetzner VPS Setup

> Automated deployment of a full TAK ecosystem on a Hetzner Cloud VPS.

## Overview

This repo contains everything needed to deploy a TAK server on a Hetzner VPS with:

| Component | Description | Source |
|-----------|-------------|--------|
| **OpenTAK Server (OTS)** | Open source TAK server — CoT routing, cert management, video streaming, live map | Installer from `i.opentakserver.io` |
| **CloudTAK** | Browser-based TAK client & ETL tool | [dfpc-coe/CloudTAK](https://github.com/dfpc-coe/CloudTAK) |
| **MediaMTX** | Video streaming (RTSP/RTMP/HLS/WebRTC/SRT) | `ghcr.io/dfpc-coe/media-infra` |
| **PostGIS** | PostgreSQL with GIS extensions (for CloudTAK) | `postgis/postgis` |
| **MinIO** | S3-compatible object storage (for CloudTAK) | `minio/minio` |

---

## Deployment Workflow

### 1. Create a Primary IP at Hetzner

In [Hetzner Cloud Console](https://console.hetzner.cloud/):

1. Go to **Networking → Primary IPs → Create Primary IP**
2. Choose location (e.g. `fsn1` Falkenstein or `nbg1` Nuremberg)
3. Select **IPv4**
4. Name it (e.g. `tak-server-ip`)
5. Note down the IP address — you'll need it for DNS

> A Primary IP persists independently of the server. You can destroy and recreate the server without losing the IP or having to update DNS.

### 2. Create DNS Records

At your DNS provider (e.g. Cloudflare), create three A records pointing to the Primary IP:

| Type | Name | Value | TTL |
|------|------|-------|-----|
| A | `tak.example.com` | `<PRIMARY_IP>` | 300 |
| A | `cloudtak.example.com` | `<PRIMARY_IP>` | 300 |
| A | `tiles.cloudtak.example.com` | `<PRIMARY_IP>` | 300 |

> Set TTL to 300 (5 min) initially. DNS propagation usually takes a few minutes.
> All three records **must** be active before creating the server (Let's Encrypt needs them).

### 3. Configure and Build cloud-init

```bash
# Clone the repo
git clone <this-repo> && cd tak/ots

# Copy example config and fill in your values
cp config.env.example config.env

# Edit config.env:
#   - Set your domains (from step 2)
#   - Paste your SSH public key
#   - Set Hetzner settings (server type, location, primary IP name)
#   - Set ADS-B coordinates (optional)
vim config.env

# Generate cloud-init.yaml
./build.sh
```

### 4. Deploy

**One-command deployment (recommended):**

```bash
./deploy.sh
```

This handles everything automatically:
1. Generates `cloud-init.yaml` from template
2. Creates a Hetzner server with your pre-allocated primary IP
3. Waits for cloud-init to finish (OTS + CloudTAK + ADS-B)

**Via Hetzner Cloud Console (manual):**

1. Go to **Servers → Create Server**
2. Choose **Location** matching your Primary IP
3. Choose **Image:** Ubuntu 24.04
4. Choose **Type:** CX31 (2 vCPU, 8 GB RAM) — recommended minimum
5. Under **Networking**, assign the Primary IP from step 1
6. Click **Cloud config** and paste the contents of the generated `cloud-init.yaml`
7. Select your SSH key
8. Click **Create & Buy Now**

**Via hcloud CLI:**

```bash
brew install hcloud         # macOS
hcloud context create tak

hcloud server create \
  --name tak-server \
  --type cx31 \
  --image ubuntu-24.04 \
  --location fsn1 \
  --primary-ipv4 <PRIMARY_IP_ID> \
  --ssh-key <your-key-name> \
  --user-data-from-file cloud-init.yaml
```

The server will automatically install and configure everything. This takes 15–30 minutes. Monitor progress:

```bash
ssh tak@tak.example.com
tail -f /var/log/tak-setup.log
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Hetzner VPS (Ubuntu 24.04)                  │
│                                                                 │
│  ┌──────────────────────┐   ┌─────────────────────────────────┐ │
│  │   OpenTAK Server     │   │         CloudTAK (Docker)       │ │
│  │   (native install)   │   │  ┌─────┐ ┌──────┐ ┌─────────┐  │ │
│  │                      │   │  │ API │ │Events│ │  Tiles  │  │ │
│  │  - CoT routing       │   │  │:5000│ │:5003 │ │  :5002  │  │ │
│  │  - Cert enrollment   │   │  └──┬──┘ └──────┘ └─────────┘  │ │
│  │  - WebUI (:8443)     │   │     │                           │ │
│  │  - TCP/SSL streaming │   │  ┌──┴──┐  ┌──────┐ ┌────────┐  │ │
│  │                      │   │  │Post │  │MinIO │ │MediaMTX│  │ │
│  │  Nginx (proxy)       │   │  │GIS  │  │:9000 │ │ :9997  │  │ │
│  │  :80 :8080 :8443     │   │  │:5433│  └──────┘ └────────┘  │ │
│  │  :8446               │   │  └─────┘                        │ │
│  └──────────────────────┘   └─────────────────────────────────┘ │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  UFW Firewall   │   fail2ban   │   unattended-upgrades     │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
         ▲                    ▲
         │ ATAK/iTAK/WinTAK  │ Browser
         │ :8088 (TCP)        │ :443 (HTTPS)
         │ :8089 (SSL)        │
```

---

## Repository Structure

| File | Description |
|------|-------------|
| `cloud-init.yaml.tpl` | Template with `{{PLACEHOLDER}}` markers — tracked in git |
| `cloud-init.yaml` | Generated output (gitignored) |
| `config.env.example` | Example configuration — safe to share |
| `config.env` | Your configuration with real values (gitignored) |
| `build.sh` | Generates `cloud-init.yaml` from template + config |
| `deploy.sh` | One-command deployment — builds cloud-init, creates Hetzner server, waits for completion |
| `scripts/setup-letsencrypt.sh` | Let's Encrypt automation for OTS nginx |
| `scripts/setup-cloudtak.sh` | CloudTAK integration with OTS (clone, nginx, certbot, server config) |
| `scripts/setup-adsb.sh` | ADS-B flight tracking via Airplanes.live |
| `scripts/setup-all.sh` | Orchestrates all setup scripts (called by cloud-init) |
| `docs/ports.md` | Complete port reference |
| `docs/dns.md` | DNS configuration guide |
| `docs/updating.md` | How to update components |
| `docs/troubleshooting.md` | Common problems and solutions |

---

## Prerequisites

### 1. Hetzner Cloud Account

Create an account at [Hetzner Cloud](https://console.hetzner.cloud/).

### 2. SSH Key

```bash
# Generate if you don't have one
ssh-keygen -t ed25519 -C "tak-server"

# Add it to Hetzner Cloud Console → Security → SSH Keys
```

### 3. DNS

Three A records pointing to your Hetzner Primary IP. See [docs/dns.md](docs/dns.md).

---

## Recommended Server Types (Hetzner)

| Type | vCPU | RAM | Disk | Price/mo | Notes |
|------|------|-----|------|----------|-------|
| CX22 | 2 | 4 GB | 40 GB | ~€4 | **Minimum** — tight with OTS + CloudTAK |
| **CX31** | **2** | **8 GB** | **80 GB** | **~€7** | **Recommended** — good balance |
| CX41 | 4 | 16 GB | 160 GB | ~€14 | For video streaming / many EUDs |

---

## What cloud-init Does

1. **Creates user** `tak` with sudo and docker group membership
2. **Installs base packages** — git, jq, htop, tmux, python3, etc.
3. **Hardens SSH** — disables root login, password auth; restricts to `tak` account
4. **Configures fail2ban** — bans IPs after 3 failed SSH attempts
5. **Enables automatic security updates** (unattended-upgrades)
6. **Installs Docker CE** + Docker Compose plugin
7. **Creates 2 GB swap** (for smaller VPS instances)
8. **Configures UFW firewall** with all required ports
9. **Runs setup-all.sh** which automatically installs:
   - OpenTAK Server
   - Let's Encrypt certificates
   - CloudTAK
   - ADS-B tracking

---

## Ports

See [docs/ports.md](docs/ports.md) for the complete port reference.

### Quick Reference

| Port | Service | Description |
|------|---------|-------------|
| 22 | SSH | Remote access |
| 80/443 | Nginx | HTTP/HTTPS |
| 8080 | Nginx → OTS | HTTP API + OAuth |
| 8443 | Nginx → OTS | HTTPS API + WebUI (mTLS) |
| 8446 | Nginx → OTS | Certificate enrollment |
| 8088 | OTS | TCP CoT streaming |
| 8089 | OTS | SSL CoT streaming |
| 5000 | CloudTAK | API (via reverse proxy) |
| 5002 | CloudTAK | Tiles (via reverse proxy) |

---

## Connecting Clients

### ATAK/iTAK/WinTAK → OpenTAK Server

**TCP (unencrypted):**
- Server: `<OTS_DOMAIN>`
- Port: `8088`
- Protocol: `TCP`

**SSL (encrypted, recommended):**
- Server: `<OTS_DOMAIN>`
- Port: `8089`
- Protocol: `SSL`
- Requires certificate — obtain via Certificate Enrollment on `:8446`

### CloudTAK (browser)

Open `https://<CLOUDTAK_DOMAIN>` in your browser.

OTS WebUI: `https://<OTS_DOMAIN>:8443`

---

## Configuration

### OpenTAK Server

Config file: `~/ots/config.yml` (on the server, as the `tak` user)

Key settings:
```yaml
OTS_SSL_STREAMING_PORT: 8089      # SSL CoT streaming
OTS_TCP_STREAMING_PORT: 8088      # TCP CoT streaming
OTS_CA_NAME: OpenTAKServer-CA     # Certificate Authority name
OTS_CA_PASSWORD: atakatak          # CA password (CHANGE THIS!)
OTS_CA_EXPIRATION_TIME: 3650      # Certificate validity (days)
```

See full docs: https://docs.opentakserver.io/configuration.html

#### ADS-B (Airplanes.live)

ADS-B tracking is configured in `config.yml`:
```yaml
OTS_ADSB_LAT: 59.3258            # Latitude
OTS_ADSB_LON: 18.0716            # Longitude
OTS_ADSB_RADIUS: 249             # Radius in nautical miles (max 250)
OTS_ADSB_GROUP: ADS-B             # Group name for ADS-B data in TAK
```

Flow: Airplanes.live API → OTS scheduled job → RabbitMQ → `cot_parser` → EUDs

> **Note:** `cot_parser` is a separate service (`systemctl status cot_parser`) that
> parses all CoT messages including ADS-B. Both `opentakserver` and `cot_parser`
> must be running for ADS-B to work.

### CloudTAK

Config file: `~/cloudtak/.env`

Key settings:
```env
API_URL=https://<CLOUDTAK_DOMAIN>         # MUST have https:// prefix
PMTILES_URL=https://<TILES_DOMAIN>
SigningSecret=<auto-generated>
POSTGRES=postgres://docker:docker@postgis:5432/gis
```

### CloudTAK Server Connection

CloudTAK requires three URLs to communicate with OTS:

| Parameter | URL | Purpose |
|-----------|-----|---------|
| `url` / `api` | `https://<OTS_DOMAIN>:8443` | Marti API (mTLS with client cert) |
| `webtak` | `http://<OTS_DOMAIN>:8080` | OAuth login (no client cert) |

> **Why different ports?** Port 8443 requires `ssl_verify_client on` (mTLS) —
> CloudTAK sends the admin client cert for API calls. Port 8080 has OAuth
> without client certificate requirement, needed for initial login.

---

## Updating

See [docs/updating.md](docs/updating.md) for detailed instructions.

### Quick Reference

```bash
# OpenTAK Server
pip install --upgrade opentakserver
sudo systemctl restart opentakserver cot_parser

# CloudTAK
cd ~/cloudtak && ./cloudtak.sh update

# Check versions
pip show opentakserver | grep Version
cd ~/cloudtak && git log --oneline -1
```

---

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for detailed solutions.

### Quick Diagnostics

```bash
# Setup log
sudo cat /var/log/tak-setup.log

# OTS status
sudo systemctl status opentakserver
journalctl -u opentakserver -f

# CloudTAK status
cd ~/cloudtak && docker compose ps
docker compose logs -f api

# Nginx
sudo nginx -t
sudo tail -f /var/log/nginx/error.log

# Firewall
sudo ufw status
```

---

## Backup

### CloudTAK

```bash
cd ~/cloudtak
./cloudtak.sh backup     # Saved to ~/cloudtak-backups/
./cloudtak.sh restore    # Pick from list
```

### OpenTAK Server

```bash
cp ~/ots/ots.db ~/ots/ots.db.backup.$(date +%Y%m%d)
```

---

## Security

### Hardened Automatically

- **SSH:** Public key auth only, `tak` account only, max 3 attempts
- **fail2ban:** Bans IPs for 1 hour after 3 failed SSH attempts
- **UFW:** Default deny incoming, only required ports open
- **Automatic updates:** Security patches installed daily
- **Swap:** 2 GB swap with `swappiness=10` (prevents OOM killer)

### Recommendations After Deploy

1. **Change the OTS CA password** from `atakatak` to something strong
2. **Restrict MinIO access** — ports 9000/9002 should not be open externally
3. **Enable 2FA** on the OTS admin account
4. **Set up regular backups** via cron

```bash
# Example: daily CloudTAK backup at 03:00
echo "0 3 * * * cd ~/cloudtak && ./cloudtak.sh backup" | crontab -
```

---

## Links & Documentation

| Resource | URL |
|----------|-----|
| OpenTAK Server docs | https://docs.opentakserver.io/ |
| OpenTAK Server GitHub | https://github.com/brian7704/OpenTAKServer |
| CloudTAK docs | https://docs.cloudtak.io/ |
| CloudTAK GitHub | https://github.com/dfpc-coe/CloudTAK |
| Hetzner Cloud | https://console.hetzner.cloud/ |
| hcloud CLI | https://github.com/hetznercloud/cli |
| ATAK/TAK | https://tak.gov/ |
