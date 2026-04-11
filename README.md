# TAK Server – Hetzner Cloud Deployment

Automated deployment of [TAK (Team Awareness Kit)](https://tak.gov/) servers on [Hetzner Cloud](https://www.hetzner.com/cloud) using cloud-init and bash scripts.

## Overview

This project provides two independent deployment pipelines for running a TAK server on Hetzner Cloud. Each variant is self-contained — you only need the one that matches your use case.

| Variant | Directory | Description |
|---------|-----------|-------------|
| **OpenTAK Server** | [`ots/`](ots/) | Open-source TAK server installed natively, nginx reverse proxy |
| **Official TAK Server** | [`tak-server/`](tak-server/) | GoC Docker release from [tak.gov](https://tak.gov), Caddy reverse proxy |

Both variants include [CloudTAK](https://github.com/dfpc-coe/CloudTAK) (web-based TAK client), Let's Encrypt TLS, server hardening (fail2ban, UFW, IP blocklist, SSH hardening), and unattended security updates. The OTS variant also includes a MapProxy tile cache with pre-configured map sources for ATAK/iTAK.

## Prerequisites

- A [Hetzner Cloud](https://www.hetzner.com/cloud) account with [`hcloud` CLI](https://github.com/hetznercloud/cli) installed
- SSH key pair for server access
- A domain with DNS pointing to a Hetzner primary IP
- *(TAK Server variant only)* TAK Server Docker zip downloaded from [tak.gov](https://tak.gov/products/tak-server)

## Quick Start

Each variant follows the same workflow:

1. **Configure:**
   ```bash
   cd tak-server  # or cd ots
   cp config.env.example config.env
   # Edit config.env with your values
   ```

2. **Deploy:**
   ```bash
   ./deploy.sh
   ```

   This builds the cloud-init payload, creates a Hetzner VM, and runs all setup scripts automatically.

See each variant's README for detailed instructions:
- [OpenTAK Server (ots/)](ots/README.md)
- [Official TAK Server (tak-server/)](tak-server/README.md)

## Project Structure

```
tak/
├── ots/                    # OpenTAK Server deployment
│   ├── config.env.example  # Configuration template
│   ├── build.sh            # Generates cloud-init.yaml from template
│   ├── deploy.sh           # Creates Hetzner VM and deploys
│   ├── users.csv.example   # Bulk user provisioning template
│   ├── scripts/            # Setup scripts (embedded in cloud-init)
│   └── docs/               # DNS, ports, troubleshooting, updating, lessons learned
├── tak-server/             # Official TAK Server deployment
│   ├── config.env.example  # Configuration template
│   ├── build.sh            # Generates cloud-init.yaml from template
│   ├── deploy.sh           # Creates Hetzner VM, uploads zip, deploys
│   ├── users.csv.example   # Bulk enrollment template
│   ├── generate-enrollment-pdf.py  # Generates enrollment PDF with QR codes
│   ├── scripts/            # Setup scripts (embedded in cloud-init)
│   └── docs/               # Enrollment, ports, iTAK findings
├── maps/                   # ATAK map source XMLs (local build)
│   ├── build-maps-package.sh  # Build data package locally
│   └── *.xml               # MOBAC map source definitions
├── maps-feature.md         # TAK maps documentation
└── README.md
```

## Security

The following files are **gitignored** and must never be committed:
- `config.env` — contains SSH keys, domains, passwords
- `users.csv` — contains real user names
- `cloud-init.yaml` — generated output containing all secrets
- `*.zip` — proprietary TAK Server installer

## License

MIT
