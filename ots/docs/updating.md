# Updating TAK Components

## Overview

There are three main components to update separately:

| Component | Method | Source |
|-----------|--------|--------|
| OpenTAK Server | `pip install --upgrade opentakserver` | PyPI |
| CloudTAK | `git pull` + `./cloudtak.sh update` | GitHub |
| MapProxy | `pip install --upgrade MapProxy` (in venv) | PyPI |
| System packages | `apt upgrade` (auto via unattended-upgrades) | Ubuntu repos |

---

## Before Every Update

```bash
# 1. Log in
ssh tak@<OTS_DOMAIN>

# 2. Note current versions
pip show opentakserver | grep Version
cd ~/cloudtak && git log --oneline -1
docker compose images

# 3. Back up
cp ~/ots/ots.db ~/ots/ots.db.pre-update.$(date +%Y%m%d)
cd ~/cloudtak && ./cloudtak.sh backup
```

---

## OpenTAK Server

```bash
# Upgrade
pip install --upgrade opentakserver

# Restart
sudo systemctl restart opentakserver

# Restart cot_parser (separate service since v1.5.0)
sudo systemctl restart cot_parser

# Verify
pip show opentakserver | grep Version
sudo systemctl status opentakserver
```

**Release notes:** https://github.com/brian7704/OpenTAKServer/releases
**Docs:** https://docs.opentakserver.io/installation/upgrading.html

### If Something Goes Wrong

```bash
# Restore database
cp ~/ots/ots.db.pre-update.YYYYMMDD ~/ots/ots.db

# Install specific version
pip install opentakserver==<VERSION>

# Restart
sudo systemctl restart opentakserver
```

---

## CloudTAK

```bash
cd ~/cloudtak

# All-in-one update (backup → pull → build → restart → verify)
./cloudtak.sh update
```

`cloudtak.sh update` automatically:
1. Backs up PostgreSQL
2. `git pull` (fetches latest code)
3. Rebuilds Docker images (`docker compose build`)
4. Restarts all services
5. Verifies the database has tables (rollback if needed)

**Release notes:** https://github.com/dfpc-coe/CloudTAK/releases
**Changelog:** https://github.com/dfpc-coe/CloudTAK/blob/main/CHANGELOG.md

### Manual Update

```bash
cd ~/cloudtak

# Backup
./cloudtak.sh backup

# Fetch latest
git pull

# Rebuild and start
docker compose build api --no-cache
docker compose build events tiles media
docker compose up -d

# Verify
docker compose ps
docker compose logs -f api
```

### If Something Goes Wrong

```bash
cd ~/cloudtak

# Revert to specific version
git log --oneline -10        # Find commit
git checkout <COMMIT_HASH>   # Go back

# Rebuild and start
docker compose build
docker compose up -d

# Or restore database
./cloudtak.sh restore
```

---

## Docker Images

CloudTAK's docker-compose.yml references specific image versions:

| Image | Version (2026-03-05) | Update |
|-------|---------------------|--------|
| `ghcr.io/dfpc-coe/media-infra` | `v8.1.0` | Update tag in docker-compose.yml |
| `postgis/postgis` | `17-3.4-alpine` | Update tag in docker-compose.yml |
| `minio/minio` | `RELEASE.2024-08-17T01-24-54Z` | Update tag in docker-compose.yml |

```bash
# After changing image tags:
cd ~/cloudtak
docker compose pull
docker compose up -d
```

---

## System Packages (Ubuntu)

Automatic security updates are enabled via `unattended-upgrades`.

```bash
# Manual update
sudo apt update && sudo apt upgrade -y

# Check if reboot is required
[ -f /var/run/reboot-required ] && echo "REBOOT NEEDED"

# Check auto-upgrade log
sudo cat /var/log/unattended-upgrades/unattended-upgrades.log
```

---

## Post-Update Checklist

- [ ] OTS Admin GUI responds: `https://<OTS_DOMAIN>/`
- [ ] CloudTAK responds: `https://<CLOUDTAK_DOMAIN>`
- [ ] Correct cert is served: `echo | openssl s_client -servername <OTS_DOMAIN> -connect <OTS_DOMAIN>:443 2>/dev/null | openssl x509 -noout -subject`
- [ ] ATAK can connect (TCP `:8088` or SSL `:8089`)
- [ ] All Docker containers running: `docker compose ps`
