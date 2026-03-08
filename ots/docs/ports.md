# Ports — TAK Server

## UFW Rules (open firewall ports)

All ports below are opened automatically by cloud-init.

### Always Open

| Port | Proto | Service | Direction | Comment |
|------|-------|---------|-----------|---------|
| 22 | TCP | SSH | Inbound | Remote access |
| 80 | TCP | Nginx | Inbound | HTTP (redirect to HTTPS) |
| 443 | TCP | Nginx | Inbound | HTTPS — WebUI, API |

### OpenTAK Server

| Port | Proto | Service | Direction | Comment |
|------|-------|---------|-----------|---------|
| 8080 | TCP | Nginx → OTS | Inbound | HTTP API + OAuth proxy |
| 8443 | TCP | Nginx → OTS | Inbound | HTTPS API + WebUI (mTLS, client cert required, LE server cert) |
| 8446 | TCP | Nginx → OTS | Inbound | Certificate enrollment (LE server cert) |
| 8088 | TCP | OTS | Inbound | TCP CoT streaming (unencrypted) |
| 8089 | TCP | OTS | Inbound | SSL CoT streaming (encrypted) |

### CloudTAK (Docker)

| Port | Proto | Service | Direction | Comment |
|------|-------|---------|-----------|---------|
| 5000 | TCP | CloudTAK API | Internal/proxy | Main app — accessed via reverse proxy |
| 5002 | TCP | Tiles | Internal/proxy | PMTiles — accessed via reverse proxy |
| 5003 | TCP | Events | Internal | Event handling |
| 5433 | TCP | PostGIS | Internal | Should NOT be exposed externally |
| 9000 | TCP | MinIO | Internal | S3 API — should NOT be exposed |
| 9002 | TCP | MinIO Console | Internal | Admin UI — should NOT be exposed |

### Video Streaming (MediaMTX)

> **Note:** OTS installs its own MediaMTX instance listening on standard ports.
> CloudTAK has its own MediaMTX in Docker. To avoid port conflicts,
> `setup-cloudtak.sh` remaps CloudTAK's media ports automatically.

**OTS MediaMTX (standard):**

| Port | Proto | Service | Direction | Comment |
|------|-------|---------|-----------|---------|
| 1935 | TCP | RTMP | Inbound | Publish/view RTMP streams |
| 8554 | TCP+UDP | RTSP | Inbound | Publish/view RTSP streams |
| 8888 | TCP | HLS | Inbound | View HLS streams in browser |
| 8889 | TCP | WebRTC | Inbound | WebRTC signaling |
| 8890 | UDP | SRT | Inbound | SRT streams |
| 8189 | UDP | WebRTC | Inbound | ICE candidates |
| 9997 | TCP | MediaMTX API | Loopback | Internal API — NOT open externally |

**CloudTAK MediaMTX (remapped ports):**

| Port | Proto | Service | Direction | Comment |
|------|-------|---------|-----------|---------|
| 8654 | TCP | RTSP | Inbound | CloudTAK RTSP (remapped from 8554) |
| 2935 | TCP | RTMP | Inbound | CloudTAK RTMP (remapped from 1935) |
| 8988 | TCP | HLS | Inbound | CloudTAK HLS (remapped from 8888) |
| 8990 | UDP | SRT | Inbound | CloudTAK SRT (remapped from 8890) |
| 9898 | TCP | Media API | Inbound | CloudTAK Media API (remapped from 9997) |

### Optional

| Port | Proto | Service | Direction | Comment |
|------|-------|---------|-----------|---------|
| 64738 | TCP+UDP | Mumble | Inbound | Voice calls |
| 1883 | TCP | RabbitMQ MQTT | Inbound | Meshtastic (unencrypted) |
| 8883 | TCP | RabbitMQ MQTTS | Inbound | Meshtastic (encrypted) |

## Internal Ports (loopback only)

These ports should **never** be exposed externally:

| Port | Service | Note |
|------|---------|------|
| 8081 | OTS API | Nginx proxies to here |
| 5432 | PostGIS (internal) | Docker-internal |
| 5672 | RabbitMQ AMQP | Internal message queue |
| 6502 | Mumble ICE | Auth integration |
| 25672 | RabbitMQ Federation | Internal |

## Security Notes

- **HSTS fix:** Ports 8443 and 8446 use Let's Encrypt server certs. Firefox applies HSTS to all ports for a domain — self-signed certs on 8443 are blocked if 443 has HSTS. mTLS (`ssl_client_certificate` + `ssl_verify_client`) is preserved.
- **server_name fix:** OTS sets `server_name opentakserver_443` etc. — `setup-letsencrypt.sh` fixes this to the real domain name so nginx serves the correct cert.
- **certbot --standalone:** CloudTAK uses `certbot certonly --standalone` (not `--nginx`) to avoid certbot rewriting OTS nginx configs.
- **NODE_TLS_REJECT_UNAUTHORIZED:** Not needed — CloudTAK trusts LE certs on 8443.
- **MinIO (9000, 9002):** Not opened by cloud-init — no external access needed.
- **PostGIS (5433):** Not opened by cloud-init — Docker-internal only.
- **RabbitMQ (5672, 25672):** Not opened — internal message queue.
- **MediaMTX port conflict:** OTS and CloudTAK each have their own MediaMTX. Kill the OTS instance.
- **Port 8080 /oauth:** OTS nginx proxies `^/(api|Marti|oauth)` — CloudTAK needs `/oauth`.
- If you don't use video/Mumble/Meshtastic, comment out those UFW rules.
