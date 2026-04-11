#!/bin/bash
# =============================================================================
# setup-mapproxy.sh — MapProxy tile cache for TAK map sources
# =============================================================================
# Installs MapProxy as a tile caching proxy with MBTiles storage.
# Tiles requested by ATAK/iTAK clients are fetched from upstream providers
# (OSM, ESRI, Lantmäteriet WMS, etc.), cached locally, and served from cache
# on subsequent requests. Avoids User-Agent blocks (OSM), reduces upstream
# load, and enables future offline tile seeding.
#
# Components:
#   - MapProxy Python venv at /opt/mapproxy
#   - gunicorn WSGI server on 127.0.0.1:8083
#   - systemd service 'mapproxy'
#   - nginx site for TILES_DOMAIN with Let's Encrypt cert
#
# Map sources proxied (all free, no API key):
#   - OpenStreetMap, OpenTopoMap
#   - ESRI Satellite, Clarity, World Topo
#   - OpenSeaMap Base Chart + Seamarks overlay
#
# Run: sudo bash /opt/scripts/setup-mapproxy.sh
# =============================================================================
set -euo pipefail

SCRIPTS_DIR="/opt/scripts"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

# Source config
[[ -f "${SCRIPTS_DIR}/config.env" ]] && source "${SCRIPTS_DIR}/config.env"

TILES_DOMAIN="${TILES_DOMAIN:?TILES_DOMAIN not set in config.env}"
OTS_DOMAIN="${OTS_DOMAIN:?OTS_DOMAIN not set in config.env}"
MAPPROXY_DIR="/opt/mapproxy"
CACHE_DIR="/var/cache/mapproxy"
MAPPROXY_PORT=8083

[[ $EUID -eq 0 ]] || err "Must be run as root"

echo ""
echo "=== Setting up MapProxy tile cache ==="
echo "Domain: ${TILES_DOMAIN}"
echo ""

# ── 1. Install system dependencies ──
info "Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq python3-venv python3-dev \
  libgeos-dev libgdal-dev libproj-dev \
  libjpeg-dev zlib1g-dev > /dev/null 2>&1
log "System dependencies installed"

# ── 2. Create venv and install MapProxy ──
if [[ ! -d "${MAPPROXY_DIR}/venv" ]]; then
  info "Creating Python venv..."
  mkdir -p "$MAPPROXY_DIR"
  python3 -m venv "${MAPPROXY_DIR}/venv"
fi

info "Installing MapProxy + gunicorn..."
"${MAPPROXY_DIR}/venv/bin/pip" install --quiet MapProxy gunicorn
MAPPROXY_VERSION=$("${MAPPROXY_DIR}/venv/bin/pip" show MapProxy | grep '^Version:' | cut -d' ' -f2)
log "MapProxy ${MAPPROXY_VERSION} installed"

# ── 3. Create cache directory ──
mkdir -p "${CACHE_DIR}/locks"
chown -R www-data:www-data "$CACHE_DIR"

# ── 4. Write MapProxy configuration ──
cat > "${MAPPROXY_DIR}/mapproxy.yaml" << 'MAPPROXY_YAML'
services:
  tms:
    use_grid_names: true
  wmts:
  demo:

sources:
  osm:
    type: tile
    url: https://tile.openstreetmap.org/%(z)s/%(x)s/%(y)s.png
    grid: webmercator
    http:
      headers:
        User-Agent: "Mozilla/5.0 (compatible; MapProxy)"

  opentopo:
    type: tile
    url: https://a.tile.opentopomap.org/%(z)s/%(x)s/%(y)s.png
    grid: webmercator
    http:
      headers:
        User-Agent: "Mozilla/5.0 (compatible; MapProxy)"

  esri_satellite:
    type: tile
    url: https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/%(z)s/%(y)s/%(x)s
    grid: webmercator

  esri_clarity:
    type: tile
    url: https://clarity.maptiles.arcgis.com/arcgis/rest/services/World_Imagery/MapServer/tile/%(z)s/%(y)s/%(x)s
    grid: webmercator

  esri_topo:
    type: tile
    url: https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/%(z)s/%(y)s/%(x)s
    grid: webmercator

  openseamap_base:
    type: tile
    url: https://t1.openseamap.org/tiles/base/%(z)s/%(x)s/%(y)s.png
    grid: webmercator

  openseamap_seamarks:
    type: tile
    url: https://tiles.openseamap.org/seamark/%(z)s/%(x)s/%(y)s.png
    grid: webmercator

caches:
  osm_cache:
    sources: [osm]
    grids: [webmercator]
    cache:
      type: mbtiles
      filename: /var/cache/mapproxy/osm.mbtiles

  opentopo_cache:
    sources: [opentopo]
    grids: [webmercator]
    cache:
      type: mbtiles
      filename: /var/cache/mapproxy/opentopo.mbtiles

  esri_satellite_cache:
    sources: [esri_satellite]
    grids: [webmercator]
    format: image/jpeg
    cache:
      type: mbtiles
      filename: /var/cache/mapproxy/esri_satellite.mbtiles

  esri_clarity_cache:
    sources: [esri_clarity]
    grids: [webmercator]
    format: image/jpeg
    cache:
      type: mbtiles
      filename: /var/cache/mapproxy/esri_clarity.mbtiles

  esri_topo_cache:
    sources: [esri_topo]
    grids: [webmercator]
    format: image/jpeg
    cache:
      type: mbtiles
      filename: /var/cache/mapproxy/esri_topo.mbtiles

  openseamap_base_cache:
    sources: [openseamap_base]
    grids: [webmercator]
    cache:
      type: mbtiles
      filename: /var/cache/mapproxy/openseamap_base.mbtiles

  openseamap_seamarks_cache:
    sources: [openseamap_seamarks]
    grids: [webmercator]
    cache:
      type: mbtiles
      filename: /var/cache/mapproxy/openseamap_seamarks.mbtiles

layers:
  - name: osm
    title: OpenStreetMap
    sources: [osm_cache]
  - name: opentopo
    title: OpenTopoMap
    sources: [opentopo_cache]
  - name: esri_satellite
    title: Esri Satellite
    sources: [esri_satellite_cache]
  - name: esri_clarity
    title: Esri Clarity
    sources: [esri_clarity_cache]
  - name: esri_topo
    title: Esri World Topo
    sources: [esri_topo_cache]
  - name: openseamap_base
    title: OpenSeaMap Base
    sources: [openseamap_base_cache]
  - name: openseamap_seamarks
    title: OpenSeaMap Seamarks
    sources: [openseamap_seamarks_cache]

grids:
  webmercator:
    srs: 'EPSG:3857'
    origin: nw

globals:
  cache:
    base_dir: '/var/cache/mapproxy'
    lock_dir: '/var/cache/mapproxy/locks'
    refresh_before:
      days: 7
  http:
    client_timeout: 60
MAPPROXY_YAML

log "MapProxy configuration written"

# ── 5. Write seed configuration ──
cat > "${MAPPROXY_DIR}/seed.yaml" << 'SEED_YAML'
# Pre-download tiles for Sweden (run manually)
# Usage:
#   /opt/mapproxy/venv/bin/mapproxy-seed \
#     -f /opt/mapproxy/mapproxy.yaml \
#     -s /opt/mapproxy/seed.yaml
#
# z0-10: ~1000 tiles per source, ~150 MB total — takes a few minutes
# z0-12: ~15000 tiles per source, ~2 GB total — takes ~30 minutes
# z0-14: ~250000 tiles per source, ~30 GB total — takes hours

seeds:
  sweden_base:
    caches: [osm_cache, opentopo_cache]
    coverages: [sweden]
    levels:
      from: 0
      to: 10

coverages:
  sweden:
    bbox: [10.5, 55.3, 24.2, 69.1]
    srs: 'EPSG:4326'
SEED_YAML

log "Seed configuration written"

# ── 6. Write WSGI entrypoint ──
cat > "${MAPPROXY_DIR}/app.py" << 'WSGI_PY'
from mapproxy.wsgiapp import make_wsgi_app
application = make_wsgi_app('/opt/mapproxy/mapproxy.yaml')
WSGI_PY

chown -R www-data:www-data "$MAPPROXY_DIR"
log "WSGI application configured"

# ── 7. Create systemd service ──
cat > /etc/systemd/system/mapproxy.service << EOF
[Unit]
Description=MapProxy Tile Cache
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=${MAPPROXY_DIR}
ExecStart=${MAPPROXY_DIR}/venv/bin/gunicorn -w 4 -b 127.0.0.1:${MAPPROXY_PORT} app:application
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mapproxy > /dev/null 2>&1
systemctl restart mapproxy

# Wait for MapProxy to respond
MAPPROXY_UP=false
for i in {1..15}; do
  if curl -sf "http://127.0.0.1:${MAPPROXY_PORT}/demo/" > /dev/null 2>&1; then
    MAPPROXY_UP=true
    break
  fi
  sleep 1
done

if [[ "$MAPPROXY_UP" == true ]]; then
  log "MapProxy service running on port ${MAPPROXY_PORT}"
else
  warn "MapProxy not responding yet — check: journalctl -u mapproxy"
fi

# ── 8. Let's Encrypt certificate ──
LE_CERT="/etc/letsencrypt/live/${TILES_DOMAIN}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/${TILES_DOMAIN}/privkey.pem"

if [[ ! -f "$LE_CERT" ]]; then
  info "Obtaining Let's Encrypt certificate for ${TILES_DOMAIN}..."

  if ! command -v certbot &>/dev/null; then
    apt-get install -y certbot > /dev/null 2>&1
  fi

  systemctl stop nginx
  certbot certonly \
    --standalone \
    --preferred-challenges http \
    --non-interactive \
    --agree-tos \
    --email "admin@${OTS_DOMAIN}" \
    -d "${TILES_DOMAIN}"
  systemctl start nginx

  [[ -f "$LE_CERT" ]] || err "Failed to obtain certificate for ${TILES_DOMAIN}"
  log "Certificate obtained for ${TILES_DOMAIN}"
else
  log "Certificate already exists for ${TILES_DOMAIN}"
fi

# ── 9. Create nginx site ──
NGINX_SITE="/etc/nginx/sites-available/mapproxy_tiles"

cat > "$NGINX_SITE" << NGINX_EOF
# MapProxy tile cache — ${TILES_DOMAIN}
# Clean URLs: /{layer}/{z}/{x}/{y}.{ext}
# Proxied to MapProxy WMTS: /wmts/{layer}/webmercator/{z}/{x}/{y}.{ext}
# WMTS uses NW origin (Y from top) which matches ATAK/XYZ convention.

server {
    listen 443 ssl http2;
    server_name ${TILES_DOMAIN};

    ssl_certificate     ${LE_CERT};
    ssl_certificate_key ${LE_KEY};

    # PNG tile requests → MapProxy WMTS
    location ~ ^/([a-z_]+)/(\d+)/(\d+)/(\d+)\.png\$ {
        proxy_pass http://127.0.0.1:${MAPPROXY_PORT}/wmts/\$1/webmercator/\$2/\$3/\$4.png;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # JPEG tile requests (.jpg -> .jpeg for MapProxy)
    location ~ ^/([a-z_]+)/(\d+)/(\d+)/(\d+)\.(jpg|jpeg)\$ {
        proxy_pass http://127.0.0.1:${MAPPROXY_PORT}/wmts/\$1/webmercator/\$2/\$3/\$4.jpeg;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # MapProxy demo UI
    location /demo/ {
        proxy_pass http://127.0.0.1:${MAPPROXY_PORT}/demo/;
        proxy_set_header Host \$host;
    }

    # Direct TMS/WMTS access (fallback)
    location /tms/ {
        proxy_pass http://127.0.0.1:${MAPPROXY_PORT}/tms/;
        proxy_set_header Host \$host;
    }
    location /wmts/ {
        proxy_pass http://127.0.0.1:${MAPPROXY_PORT}/wmts/;
        proxy_set_header Host \$host;
    }
}
NGINX_EOF

# Enable site
ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/mapproxy_tiles

# Test and reload
if nginx -t 2>/dev/null; then
  systemctl reload nginx
  log "nginx configured for ${TILES_DOMAIN}"
else
  nginx -t
  err "nginx config test failed — check the config above"
fi

echo ""
echo "=== MapProxy tile cache setup complete ==="
echo ""
echo "Tiles: https://${TILES_DOMAIN}/{layer}/{z}/{x}/{y}.{ext}"
echo "Demo:  https://${TILES_DOMAIN}/demo/"
echo ""
echo "Layers: osm, opentopo, esri_satellite, esri_clarity, esri_topo,"
echo "        lantmateriet, openseamap_base, openseamap_seamarks"
echo ""
echo "Seed tiles (optional):"
echo "  ${MAPPROXY_DIR}/venv/bin/mapproxy-seed \\"
echo "    -f ${MAPPROXY_DIR}/mapproxy.yaml -s ${MAPPROXY_DIR}/seed.yaml"
