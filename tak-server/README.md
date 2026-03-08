# TAK Server (GoC) — Automated Hetzner Deployment

One-command deployment of the **official TAK Server** (from [tak.gov](https://tak.gov)) onto a Hetzner Cloud VPS using `hcloud` CLI + cloud-init.

## What It Deploys

| Component | Description |
|-----------|-------------|
| **TAK Server** | Official Docker release from tak.gov (TAK Server + PostgreSQL containers) |
| **Let's Encrypt** | Trusted TLS certificate for the web UI |
| **Server hardening** | SSH hardening, fail2ban, UFW, ipsum blocklist, unattended-upgrades |

## Prerequisites

1. **TAK Server Docker zip** — Download from [tak.gov/products/tak-server](https://tak.gov/products/tak-server) (free account required, select the **Docker** release)
2. **hcloud CLI** — `brew install hcloud` (then `hcloud context create` to authenticate)
3. **A Hetzner primary IP** — Pre-allocate in the console or via `hcloud primary-ip create --name tak-ip --type ipv4 --datacenter fsn1-dc14`
4. **A domain** with a DNS A record pointing to the primary IP

## Quick Start

```bash
# 1. Copy and edit config
cp config.env.example config.env
nano config.env

# 2. Place the Docker zip in this directory
cp ~/Downloads/takserver-docker-5.3-RELEASE-1.zip .

# 3. Deploy (creates server, uploads zip, installs everything)
./deploy.sh
```

That's it. `deploy.sh` handles all five steps automatically:

1. Generates `cloud-init.yaml` from the template
2. Creates a Hetzner server with your pre-allocated primary IP
3. Waits for cloud-init to finish (base system, Docker, hardening)
4. SCPs the TAK Server zip to the server
5. SSHs in and runs the installation scripts

## Configuration

Edit `config.env` before deploying:

### TAK Server

| Variable | Description | Example |
|----------|-------------|---------|
| `TAK_HOSTNAME` | Server hostname | `tak-server` |
| `TAK_TIMEZONE` | Timezone | `Europe/Stockholm` |
| `TAK_LOCALE` | System locale | `sv_SE.UTF-8` |
| `SSH_PUBLIC_KEY` | Your SSH public key | `ssh-ed25519 AAAA...` |
| `TAK_DOMAIN` | Domain name for TAK Server | `tak.example.com` |
| `CERTBOT_EMAIL` | Email for Let's Encrypt notifications | `admin@example.com` |
| `TAK_ZIP_FILENAME` | Filename of the Docker zip in this directory | `takserver-docker-5.3-RELEASE-1.zip` |
| `TAK_CA_PASS` | Password for the TAK CA and keystores | (change from default) |
| `TAK_ADMIN_PASS` | Password for admin certificate | (change from default) |

### Hetzner

| Variable | Description | Default |
|----------|-------------|---------|
| `HETZNER_SERVER_TYPE` | Server type ([docs](https://docs.hetzner.com/cloud/servers/overview#shared-vcpu)) | `cx33` |
| `HETZNER_IMAGE` | OS image | `ubuntu-22.04` |
| `HETZNER_LOCATION` | Datacenter location | `fsn1` |
| `HETZNER_PRIMARY_IP` | Name of a pre-allocated primary IP | `tak-ip` |

## After Deployment

### Download admin certificate

```bash
scp tak@tak.example.com:~/certs/admin.p12 .
```

### Access web UI

Import `admin.p12` into your browser, then open:

```
https://tak.example.com:8443
```

### Connect ATAK

1. Import the client `.p12` certificate into ATAK
2. Add server: `tak.example.com:8089` (SSL)

### Server management

```bash
# SSH into the server
ssh tak@tak.example.com

# TAK Server status
cd /opt/tak && docker compose ps

# TAK Server logs
cd /opt/tak && docker compose logs -f

# Setup log (from initial install)
cat /var/log/tak-setup.log
```

## Notes

- **Ubuntu 22.04** is required — matches the TAK Server Docker base image
- The ~500 MB Docker zip is uploaded via SCP after server creation (too large for cloud-init's 32 KB limit)
- Certificate passwords default to `atakatak` — **change them in `config.env`**
- The admin `.p12` certificate is copied to `/home/tak/certs/` for easy download
- The server is created with `--without-ipv6` — only the primary IPv4 is used
- If a server with the same name already exists, `deploy.sh` will prompt to delete and recreate it

## References

- [TAK Server on tak.gov](https://tak.gov/products/tak-server)
- [Let's Build a TAK Server (mytecknet.com)](https://mytecknet.com/lets-build-a-tak-server/)
- [Cloud-RF/tak-server (GitHub)](https://github.com/Cloud-RF/tak-server)

## File Structure

```
tak-server/
├── deploy.sh                # One-command deployment (hcloud + SCP + SSH)
├── build.sh                 # Generates cloud-init.yaml from template
├── config.env.example       # Configuration template
├── config.env               # Your config (gitignored)
├── cloud-init.yaml.tpl      # Cloud-init template with placeholders
├── cloud-init.yaml          # Generated output (gitignored)
├── takserver-docker-*.zip   # TAK Server Docker release (you provide)
├── scripts/
│   ├── setup-all.sh         # Orchestrator — runs setup-tak + setup-letsencrypt
│   ├── setup-tak.sh         # Extracts zip, builds Docker image, starts containers
│   └── setup-letsencrypt.sh # Let's Encrypt cert with PKCS12/JKS conversion
├── docs/
│   └── ports.md             # Firewall rules and port reference
└── README.md
```
