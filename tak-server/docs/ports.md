# TAK Server (GoC) — Ports

Firewall rules configured by cloud-init.

## Inbound Ports

| Port | Protocol | Service | Description |
|------|----------|---------|-------------|
| 22 | TCP | SSH | Remote administration |
| 80 | TCP | HTTP | Caddy ACME challenge + certbot |
| 443 | TCP | HTTPS | Caddy reverse proxy (CloudTAK + Tiles) |
| 8089 | TCP | SSL CoT | Secure Cursor-on-Target — primary ATAK connection |
| 8443 | TCP | HTTPS | TAK Server Web UI and API |
| 8446 | TCP | HTTPS | Certificate enrollment + OAuth (clientAuth=false) |
| 9000 | TCP | Federation | Federation v1 (TAK Server to TAK Server) |
| 9001 | TCP | Federation | Federation v2 (TAK Server to TAK Server) |

## Internal Ports (not exposed to internet)

These ports are used internally by Docker containers and Caddy.

| Port | Service | Description |
|------|---------|-------------|
| 5000 | CloudTAK API | Main CloudTAK application (proxied via Caddy on 443) |
| 5002 | CloudTAK Tiles | PMTiles tile server (proxied via Caddy on 443) |
| 5003 | CloudTAK Events | Event handling service |
| 5433 | CloudTAK PostGIS | PostgreSQL + PostGIS database |
| 9100 | MinIO API | S3-compatible object storage (remapped from 9000) |
| 9102 | MinIO Console | MinIO web console (remapped from 9002) |

## ATAK Client Configuration

Connect ATAK to the server using:
- **Address:** `your-domain.com`
- **Port:** `8089`
- **Protocol:** SSL
- **Client certificate:** Import the `.p12` generated during setup

## Admin Web UI

Access the admin interface at:
```
https://your-domain.com:8443
```
Import the `admin.p12` certificate into your browser to authenticate.

## CloudTAK

Access CloudTAK at:
```
https://cloudtak.your-domain.com
```

**Login:** Use your TAK Server username and password.

### Adding a new CloudTAK user

Each user needs: a TAK Server account with password, a client certificate, and
a CloudTAK profile entry. The GoC TAK Server does not have `<certificateSigning>`
configured, so auto-enrollment is not available — certs must be pre-generated.

```bash
# 1. Create TAK user with password
docker exec takserver java -jar /opt/tak/utils/UserManager.jar \
  usermod -A -p "YourPassword123!" username

# 2. Generate client cert
docker exec takserver bash -c \
  "cd /opt/tak/certs && CAPASS=YOUR_CA_PASS ./makeCert.sh client username"

# 3. Grant __ANON__ group (required for API access)
docker exec takserver java -jar /opt/tak/utils/UserManager.jar \
  usermod -g __ANON__ username

# 4. Inject profile into CloudTAK DB (run inject_profile.py helper)
scp inject_profile.py tak@your-server:/tmp/
ssh tak@your-server "python3 /tmp/inject_profile.py"
```

Password must be min 15 chars with 1 uppercase, 1 lowercase, 1 digit, 1 special character.

**How it works:**
- CloudTAK authenticates users via OAuth on port **8446** (`clientAuth=false`)
- CloudTAK connects to the TAK Server API via mTLS on port **8443**
- The TAK Server CA cert is mounted into the CloudTAK container via `NODE_EXTRA_CA_CERTS`
- `extra_hosts: ["takserver:host-gateway"]` maps the hostname `takserver` to the Docker host IP
- The TAK Server cert SAN is `DNS:takserver`, so CloudTAK uses hostname `takserver` (not the domain) for all backend connections

## Federation

To federate with other TAK Servers:
- **Port 9000** — Federation v1 (legacy)
- **Port 9001** — Federation v2 (recommended)

Configure federation in the TAK Server web UI under Federations.
