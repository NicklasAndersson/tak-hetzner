# Troubleshooting — TAK Server

## Quick Reference

```bash
# Log in
ssh tak@<OTS_DOMAIN>

# General status
sudo systemctl status opentakserver
cd ~/cloudtak && docker compose ps
sudo ufw status
sudo fail2ban-client status
```

---

## Cloud-init

### Setup script didn't finish

```bash
# Check status
sudo cloud-init status --long

# Read the log
sudo cat /var/log/tak-setup.log

# Cloud-init log
sudo cat /var/log/cloud-init-output.log

# Re-run
sudo cloud-init clean
sudo cloud-init init
```

### Still waiting (can take 15–30 min)

```bash
# Check if the process is still running
ps aux | grep tak-setup
tail -f /var/log/tak-setup.log
```

---

## OpenTAK Server

### OTS won't start

```bash
journalctl -u opentakserver -f --no-pager | tail -50

# Check config
cat ~/ots/config.yml

# Test manual start
opentakserver
```

### Can't reach WebUI (:8443)

```bash
# Check nginx
sudo systemctl status nginx
sudo nginx -t
sudo tail -20 /var/log/nginx/error.log

# Check that OTS is listening on 8081
ss -tlnp | grep 8081

# Check UFW
sudo ufw status | grep 8443
```

### ATAK can't connect

```bash
# Check that ports are open
ss -tlnp | grep -E '8088|8089'
sudo ufw status | grep -E '8088|8089'

# Test TCP connection from outside (run locally, not on the server)
nc -vz <OTS_DOMAIN> 8088
nc -vz <OTS_DOMAIN> 8089

# Check OTS logs
journalctl -u opentakserver | grep -i "error\|fail\|except" | tail -20
```

### Certificate enrollment not working

```bash
# Check that CA exists
ls -la ~/ots/ca/

# Check cert enrollment port
ss -tlnp | grep 8446
sudo ufw status | grep 8446

# Test
curl -k https://<OTS_DOMAIN>:8446/Marti/api/tls/config
```

### cot_parser not running

`cot_parser` is a separate service (since OTS v1.5.0) that parses all CoT messages
via RabbitMQ. Without `cot_parser`, ADS-B, EUD routing, and other CoT flows won't work.

```bash
# Check status
sudo systemctl status cot_parser

# Check that the process is running
ps aux | grep cot_parser

# Restart
sudo systemctl restart cot_parser

# Logs
journalctl -u cot_parser -f --no-pager | tail -30
```

### ADS-B (Airplanes.live) not showing aircraft

**1. Verify correct config keys are used:**
```bash
# CORRECT keys (OTS_ADSB_*)
grep -E 'OTS_ADSB_LAT|OTS_ADSB_LON|OTS_ADSB_RADIUS' ~/ots/config.yml

# WRONG: Old keys (OTS_AIRPLANES_LIVE_*) — don't work
grep 'OTS_AIRPLANES_LIVE' ~/ots/config.yml
# If these exist, run: sudo bash /opt/scripts/setup-adsb.sh
```

**2. Verify the scheduled job is enabled:**
```bash
grep -A5 'get_adsb_data' ~/ots/config.yml
# next_run_time MUST have a date (not null)
# If null: run sudo bash /opt/scripts/setup-adsb.sh
```

**3. Verify all three services are running:**
```bash
sudo systemctl status opentakserver cot_parser
ps aux | grep -E 'opentakserver|cot_parser|eud_handler' | grep -v grep
```

**4. Check logs:**
```bash
# Search for ADS-B activity in logs
grep 'get_adsb_data' ~/ots/logs/opentakserver.log | tail -10

# Search for errors
grep -i 'error\|fail\|exception' ~/ots/logs/opentakserver.log | tail -20
```

**5. Test the API manually:**
```bash
# Test the Airplanes.live API directly
curl -s "https://api.airplanes.live/v2/point/<LAT>/<LON>/50" | python3 -m json.tool | head -20
```

---

## CloudTAK

### Containers won't start

```bash
cd ~/cloudtak

# Status
docker compose ps

# Logs per service
docker compose logs postgis  2>&1 | tail -30
docker compose logs api      2>&1 | tail -30
docker compose logs events   2>&1 | tail -30
docker compose logs tiles    2>&1 | tail -30
docker compose logs media    2>&1 | tail -30
docker compose logs store    2>&1 | tail -30

# Restart everything
docker compose down
docker compose up -d postgis store
sleep 10
docker compose up -d api events tiles media
```

### API not responding (port 5000)

```bash
# Check that the container is running
docker compose ps api

# Check logs
docker compose logs -f api

# Check .env
cat ~/cloudtak/.env

# Test locally
curl http://localhost:5000
```

### Database problems

```bash
cd ~/cloudtak

# Connect directly to the database
./cloudtak.sh connect

# Check tables
docker exec cloudtak-postgis-1 psql -d postgres://docker:docker@localhost:5432/gis \
  -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';"

# Restore from backup
./cloudtak.sh restore
```

### Docker using too much disk space

```bash
# Show disk usage
docker system df
df -h

# Clean unused images
cd ~/cloudtak && ./cloudtak.sh clean

# Aggressive cleanup (removes ALL unused)
docker system prune -a --volumes
```

---

## Firewall (UFW)

### Check status

```bash
sudo ufw status verbose
sudo ufw status numbered
```

### Add a port

```bash
sudo ufw allow <PORT>/<PROTO> comment 'Description'
# Example:
sudo ufw allow 1883/tcp comment 'MQTT Meshtastic'
```

### Remove a rule

```bash
sudo ufw status numbered
sudo ufw delete <NUMBER>
```

### Reset everything

```bash
sudo ufw reset
# Then re-run the UFW section from tak-setup.sh
```

---

## Fail2ban

### Check status

```bash
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

### Unban an IP

```bash
sudo fail2ban-client set sshd unbanip <IP>
```

### View banned IPs

```bash
sudo fail2ban-client status sshd | grep "Banned IP"
```

---

## Network Diagnostics

```bash
# DNS lookup
dig +short <OTS_DOMAIN>
dig +short <TILES_DOMAIN>

# Check open ports from outside (run locally)
nmap -p 22,80,443,8080,8088,8089,8443,8446 <OTS_DOMAIN>

# Check listening ports on server
ss -tlnp
ss -ulnp

# Check processes
ps aux | grep -E 'opentakserver|docker|nginx|rabbitmq'
```

---

## Resources & Performance

```bash
# RAM & CPU
htop
free -h

# Disk
df -h
du -sh ~/cloudtak /var/lib/docker ~/ots

# Docker resources per container
docker stats --no-stream

# Swap
swapon --show
cat /proc/swaps
```

---

## Common Error Messages

| Error Message | Cause | Solution |
|---------------|-------|----------|
| `Connection refused :8089` | OTS SSL port not running | Check `journalctl -u opentakserver` |
| `502 Bad Gateway` | Nginx can't reach OTS backend | Check that OTS is listening on :8081 |
| `FATAL: password authentication failed` | Wrong DB password | Check `POSTGRES=` in .env |
| `no space left on device` | Disk full | `docker system prune -a` + `apt autoremove` |
| `Address already in use` | Port occupied | `ss -tlnp \| grep <PORT>` — kill the conflict |
| `certificate verify failed` | Certificate problem | Enroll new cert via :8446 |

---

## Deployment-Specific Issues

### HSTS / Certificate Mismatch: "Uses a certificate that is not valid"

**Symptom:** Firefox shows an HSTS security policy error or says the certificate
is only valid for different domains.

**Cause:** Two issues:
1. **`certbot --nginx`** rewrites ALL nginx SSL configs, including the OTS domain's,
   replacing the OTS cert with the CloudTAK cert.
2. **OTS nginx `server_name`** is set to internal names (`opentakserver_443` etc.)
   instead of the domain name. When CloudTAK adds its own 443 blocks, nginx matches
   the CloudTAK block for OTS requests → wrong cert is served.

**Fix on the server:**
```bash
# 1. Fix server_name in OTS nginx configs
sudo sed -i 's/server_name opentakserver_443;/server_name <OTS_DOMAIN>;/' /etc/nginx/sites-enabled/ots_https
sudo sed -i 's/server_name opentakserver_8443;/server_name <OTS_DOMAIN>;/' /etc/nginx/sites-enabled/ots_https
sudo sed -i 's/server_name opentakserver_8446;/server_name <OTS_DOMAIN>;/' /etc/nginx/sites-enabled/ots_certificate_enrollment

# 2. Verify that OTS configs point to the correct cert
grep ssl_certificate /etc/nginx/sites-enabled/ots_https
# Should show: /etc/letsencrypt/live/<OTS_DOMAIN>/ (NOT <CLOUDTAK_DOMAIN>)

# 3. Test and reload
sudo nginx -t && sudo systemctl reload nginx

# 4. Verify
echo | openssl s_client -servername <OTS_DOMAIN> -connect <OTS_DOMAIN>:443 2>/dev/null | openssl x509 -noout -subject
# Should show: subject=CN=<OTS_DOMAIN>
```

**In Firefox:** Clear HSTS cache: History → Show All History → search for your domain
→ right-click → "Forget About This Site".

> **Prevention (v3.2.0+):** `setup-letsencrypt.sh` fixes `server_name` automatically.
> `setup-cloudtak.sh` uses `certbot certonly --standalone` instead of `certbot --nginx`.

### CloudTAK: "Server has not been configured"

CloudTAK shows "Server has not been configured" at login.

**Cause:** `PATCH /api/server` hasn't been run, or it failed.

```bash
# Check status
curl -s http://localhost:5000/api/server | python3 -m json.tool

# If "status": "unconfigured" — run setup-cloudtak.sh again
# or configure manually, see below
```

### CloudTAK: "Non-200 Response from Auth Server - Token"

**Cause:** CloudTAK tries to do OAuth login (`POST /oauth/token`) against the TAK server
but gets an error response.

**Common causes:**
1. **webtak URL points to port 8443** — 8443 requires a client cert (mTLS), but OAuth is done
   with a regular fetch without a cert. Fix: `webtak` should point to port 8080.
2. **OTS nginx missing /oauth location** — `/oauth/token` doesn't match `^/(api|Marti)`
   and falls through to `try_files` (405). Fix: change to `^/(api|Marti|oauth)`.
3. **Wrong cert type** — the server cert (CN=opentakserver) was sent instead of the admin client cert.

```bash
# Check that OAuth works on 8080
curl -s -X POST "http://localhost:8080/oauth/token?grant_type=password&username=administrator&password=<PASSWORD>"

# Check nginx location
grep 'location ~ ' /etc/nginx/sites-enabled/ots_http
# Should match: location ~ ^/(api|Marti|oauth) {

# Fix if /oauth is missing
sudo python3 -c "
with open('/etc/nginx/sites-enabled/ots_http') as f:
    c = f.read()
c = c.replace('(api|Marti) {', '(api|Marti|oauth) {')
with open('/etc/nginx/sites-enabled/ots_http', 'w') as f:
    f.write(c)
"
sudo nginx -t && sudo systemctl reload nginx
```

### CloudTAK: "fetch failed" during server configuration

**Cause:** Node.js rejects self-signed cert from OTS.

> **Note (v3.2.0+):** If Let's Encrypt is installed, `NODE_TLS_REJECT_UNAUTHORIZED=0`
> is NOT needed — LE certs are trusted.
> `setup-cloudtak.sh` removes this variable automatically.

```bash
# Check if NODE_TLS exists (should NOT exist with LE certs)
grep NODE_TLS ~/cloudtak/docker-compose.yml

# If the problem persists despite LE certs, check that OTS nginx
# is using the correct cert:
echo | openssl s_client -servername <OTS_DOMAIN> -connect <OTS_DOMAIN>:8443 2>/dev/null | openssl x509 -noout -subject
# Should show: subject=CN=<OTS_DOMAIN> (not <CLOUDTAK_DOMAIN>)
```

### OTS MediaMTX blocking CloudTAK media container

**Cause:** OTS installs MediaMTX listening on port 1935 (RTMP) and 8554 (RTSP).
CloudTAK has its own MediaMTX in Docker that needs the same ports.

```bash
# Check if OTS MediaMTX is running
pgrep -x mediamtx

# Kill it
sudo kill $(pgrep -x mediamtx)

# Permanently disable (if systemd service exists)
sudo systemctl stop mediamtx 2>/dev/null
sudo systemctl disable mediamtx 2>/dev/null
```

### nginx: proxy_pass has stray backslash

**Symptom:** CloudTAK page doesn't load, nginx error log shows parsing errors.

**Cause:** If the nginx config was created with an unquoted heredoc, `$http_upgrade`
can expand to empty, and `;` can be escaped to `\;`.

```bash
# Check
grep 'proxy_pass.*\\;' /etc/nginx/sites-enabled/cloudtak

# Fix
sudo sed -i 's|proxy_pass http://localhost:5000\\;|proxy_pass http://localhost:5000;|' /etc/nginx/sites-enabled/cloudtak
sudo sed -i 's|proxy_pass http://localhost:5002\\;|proxy_pass http://localhost:5002;|' /etc/nginx/sites-enabled/cloudtak
sudo nginx -t && sudo systemctl reload nginx
```

### CloudTAK manual server configuration

If setup-cloudtak.sh failed to configure the server connection:

```bash
# 1. Generate admin client cert (if not already done)
python3 << 'PYEOF'
import requests
s = requests.session()
r = s.get("http://localhost:8081/api/login", json={})
csrf = r.json()["response"]["csrf_token"]
s.headers["X-XSRF-TOKEN"] = csrf
s.headers["Referer"] = "http://localhost:8081"
s.post("http://localhost:8081/api/login", json={"username": "administrator", "password": "YOUR_PASSWORD"})
s.post("http://localhost:8081/api/certificate", json={"username": "administrator"})
print("Cert generated")
PYEOF

# 2. Configure CloudTAK
python3 << 'PYEOF'
import requests, json, os
home = os.path.expanduser("~")
with open(f"{home}/ots/ca/certs/administrator/administrator.pem") as f:
    cert = f.read()
with open(f"{home}/ots/ca/ca.pem") as f:
    ca = f.read()
with open(f"{home}/ots/ca/certs/administrator/administrator.nopass.key") as f:
    key = f.read()
r = requests.patch("http://localhost:5000/api/server", json={
    "name": "TAK Server",
    "url": "https://<OTS_DOMAIN>:8443",
    "api": "https://<OTS_DOMAIN>:8443",
    "webtak": "http://<OTS_DOMAIN>:8080",
    "auth": {"cert": cert.strip() + "\n" + ca.strip() + "\n", "key": key},
    "username": "administrator", "password": "YOUR_PASSWORD"
})
print(r.status_code, r.text[:200])
PYEOF
```
