# Maps & Geospatial Data in TAK

How to add maps, tile layers, offline tiles, and data overlays to TAK Server (official GoC) and OpenTAK Server deployments. Covers distribution to ATAK, iTAK, and CloudTAK clients.

## Overview

There are three ways to get maps to TAK clients:

| Method | Best for | Clients | Real-time updates | Requires connectivity |
|--------|----------|---------|-------------------|-----------------------|
| **Map Layers API** | Online tile sources (OSM, ESRI, WMS) | ATAK, iTAK (via missions) | Yes — update once, all EUDs sync | Yes |
| **Data Packages** | Offline tiles, map source XMLs, KML overlays | ATAK, iTAK | No — one-time download | Only for initial download |
| **CloudTAK Hosted Tilesets** | PMTiles for the web client | CloudTAK | Yes | Yes |
| **MapProxy Tile Cache** | Proxied & cached tile sources (OTS deployment) | ATAK, iTAK | Yes — cache refreshes every 7 days | Yes |

## Supported Formats

### Tile Sources (Online)

| Format | ATAK | iTAK | CloudTAK | Notes |
|--------|------|------|----------|-------|
| XYZ/TMS (slippy tiles) | Yes | Yes | Yes | `{z}/{x}/{y}.png` — most common |
| WMS | Yes | Yes | Yes | OGC standard, request tiles by bbox |
| WMTS | Yes | Yes | Yes | OGC tiled standard, pre-rendered |
| Quadkey | Yes | Yes | Yes | Bing Maps style `{q}` |
| ESRI MapServer/ImageServer | Yes | Partial | Yes | ArcGIS REST services |

### Offline Tile Formats

| Format | ATAK | iTAK | CloudTAK | Notes |
|--------|------|------|----------|-------|
| MBTiles (.mbtiles) | Yes | Yes | No | SQLite-based, most common offline format |
| GeoPackage (.gpkg) | Yes | Yes | No | OGC standard, raster tiles + vector features |
| PMTiles (.pmtiles) | No | No | Yes | Cloud-optimized single-file, for CloudTAK tile server |

### Elevation & Imagery

| Format | ATAK | iTAK | Notes |
|--------|------|------|-------|
| GeoTIFF (.tif) | Yes | Yes | Imagery overlays and DEMs |
| DTED (.dt0/.dt1/.dt2) | Yes | Yes | Elevation data for terrain analysis |

### Vector / Overlay Formats

| Format | ATAK | iTAK | CloudTAK | Notes |
|--------|------|------|----------|-------|
| KML/KMZ | Yes | Yes | Yes | Google Earth format, widely supported |
| GeoJSON | Import | No | Yes | CloudTAK has native import |
| GPX | Yes | Yes | No | GPS tracks and waypoints |
| Shapefile (.shp) | Plugin | No | No | Convert to KML: `ogr2ogr -f KML out.kml in.shp` |

---

## Method 1: Map Layers API (Official TAK Server)

The cleanest way to push online map sources to all connected EUDs. Create a map layer once via the Marti API and it syncs automatically to mission subscribers.

> **Note:** This is an official TAK Server feature. OpenTAK Server does not have the Map Layers API — use data packages instead (Method 2).

### Global Map Layer

Available to all clients:

```bash
# Extract admin cert for API access
openssl pkcs12 -in admin.p12 -out admin.pem -nodes -passin pass:atakatak \
  -provider legacy -provider default

# Create a global map layer
curl -k --cert admin.pem \
  -H "Content-Type: application/json" \
  -X POST "https://${TAK_DOMAIN}:8443/Marti/api/maplayers" \
  -d '{
    "name": "OpenStreetMap",
    "description": "OSM standard tile layer",
    "type": "XYZ",
    "url": "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
    "tileType": "png",
    "minZoom": 0,
    "maxZoom": 19,
    "defaultLayer": false,
    "enabled": true,
    "ignoreErrors": true,
    "invertYCoordinate": false,
    "opacity": 100
  }'
```

### Mission-Scoped Map Layer

Only visible to clients subscribed to the mission:

```bash
curl -k --cert admin.pem \
  -H "Content-Type: application/json" \
  -X POST "https://${TAK_DOMAIN}:8443/Marti/api/missions/${MISSION_NAME}/maplayers" \
  -d '{
    "name": "ESRI World Imagery",
    "type": "XYZ",
    "url": "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
    "tileType": "jpg",
    "minZoom": 0,
    "maxZoom": 19,
    "enabled": true
  }'
```

### Map Layers API Reference

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/Marti/api/maplayers` | Create global map layer |
| `PUT` | `/Marti/api/maplayers` | Update global map layer |
| `GET` | `/Marti/api/maplayers/all` | List all global layers |
| `GET` | `/Marti/api/maplayers/{uid}` | Get specific layer |
| `DELETE` | `/Marti/api/maplayers/{uid}` | Delete layer |
| `POST` | `/Marti/api/missions/{name}/maplayers` | Create mission layer |
| `PUT` | `/Marti/api/missions/{name}/maplayers` | Update mission layer |
| `DELETE` | `/Marti/api/missions/{name}/maplayers/{uid}` | Delete mission layer |

### Map Layer JSON Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Display name |
| `description` | string | Optional description |
| `type` | string | `XYZ`, `WMS`, `WMTS`, `Quadkey`, `ESRI` |
| `url` | string | Tile URL template (`{z}/{x}/{y}` for XYZ, base URL for WMS) |
| `tileType` | string | `png`, `jpg`, `pbf` (vector tiles) |
| `minZoom` / `maxZoom` | int | Zoom level range |
| `layers` | string | WMS/WMTS layer name |
| `version` | string | WMS/WMTS version (prefer `1.1.1` for WMS) |
| `coordinateSystem` | string | e.g. `EPSG:3857` |
| `serverParts` | string | Multi-server subdomains: `a,b,c` |
| `invertYCoordinate` | bool | `true` for TMS (inverted Y), `false` for XYZ |
| `defaultLayer` | bool | Default basemap |
| `enabled` | bool | Active layer |
| `opacity` | int | 0–100 |
| `ignoreErrors` | bool | Skip unavailable tiles |
| `backgroundColor` | string | Fallback color hex |
| `additionalParameters` | string | Extra query params |

---

## Method 2: Data Packages

A data package is a `.zip` file with a manifest that ATAK/iTAK know how to unpack. Use this for distributing offline tiles (MBTiles), map source XML configs, KML overlays, or any combination.

### Data Package Structure

```
maps-package.zip
├── MANIFEST/
│   └── manifest.xml
├── maps/
│   └── osm-source.xml          # Map source definition
├── imagery/
│   └── area-tiles.mbtiles      # Offline tile file
└── overlays/
    └── boundaries.kml           # KML overlay
```

### manifest.xml

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MissionPackageManifest version="2">
    <Configuration>
        <Parameter name="uid" value="maps-package-001"/>
        <Parameter name="name" value="Maps Package"/>
    </Configuration>
    <Contents>
        <Content ignore="false" zipEntry="maps/osm-source.xml">
            <Parameter name="contentType" value="Preference File"/>
        </Content>
        <Content ignore="false" zipEntry="imagery/area-tiles.mbtiles">
            <Parameter name="contentType" value="MBTiles"/>
        </Content>
        <Content ignore="false" zipEntry="overlays/boundaries.kml">
            <Parameter name="contentType" value="KML"/>
        </Content>
    </Contents>
</MissionPackageManifest>
```

### Upload via Marti API

Works on both official TAK Server and OpenTAK Server:

```bash
# Upload data package
curl -k --cert admin.pem \
  -F "assetfile=@maps-package.zip" \
  "https://${TAK_DOMAIN}:8443/Marti/sync/missionupload?hash=auto&filename=maps-package.zip&creatorUid=admin"

# List uploaded packages
curl -k --cert admin.pem \
  "https://${TAK_DOMAIN}:8443/Marti/api/sync/search?keyword=maps"
```

### OpenTAK Server Additional Endpoints

OTS has its own data package API alongside the standard Marti endpoints:

```bash
# Upload
curl -F "file=@maps-package.zip" "https://${OTS_DOMAIN}:8443/api/data_packages"

# List
curl "https://${OTS_DOMAIN}:8443/api/data_packages"
```

### Auto-Push on Enrollment/Connection

Data packages can be pushed automatically when clients connect. Use the device profile API:

```bash
# Create a profile
curl -k --cert admin.pem \
  -X POST "https://${TAK_DOMAIN}:8443/Marti/api/device/profile/maps-profile"

# Attach the data package to the profile
curl -k --cert admin.pem \
  -X PUT \
  -F "resource=@maps-package.zip" \
  "https://${TAK_DOMAIN}:8443/Marti/api/device/profile/maps-profile/file"
```

Clients receive the package on next connection via `/Marti/api/device/profile/connection`.

---

## Method 3: CloudTAK Hosted Tilesets

CloudTAK includes a PMTiles tile server running on port 5002, already wired up via `TILES_DOMAIN` in our deployment. It serves tiles from MinIO/S3.

### DNS (Already Configured)

```
A  cloudtak.example.com        → CloudTAK API & Web UI (port 5000)
A  tiles.cloudtak.example.com  → CloudTAK Tile Server (port 5002)
```

The tile subdomain must be a child of the CloudTAK domain (CSP headers enforce this).

### Upload Tilesets

1. Log in to CloudTAK as admin
2. Go to **Admin Panel → Hosted Tilesets**
3. Upload a `.pmtiles` file
4. Create a **Basemap** or **Overlay** entry pointing to the hosted tileset

### Pre-Built Global Basemap

CloudTAK provides a ready-made OpenMapTiles vector basemap:
- Download from: https://files.cloudtak.io/ (`openmaptiles.pmtiles`)
- Upload to CloudTAK admin → Hosted Tilesets

### CloudTAK Tile URL Patterns

| Type | URL Format |
|------|-----------|
| ZXY | `https://example.com/tiles/{z}/{x}/{y}.png` |
| Quadkey | `https://example.com/tiles/{q}.png` |
| ESRI ImageServer | `https://example.com/arcgis/rest/services/WorldImagery/ImageServer` |
| ESRI MapServer | `https://example.com/arcgis/rest/services/WorldTopo/MapServer/1` |
| PMTiles (hosted) | Select from "Public Tilesets" dropdown in admin |

---

## Method 4: MapProxy Tile Cache (OTS Deployment)

The OTS deployment includes a MapProxy tile cache that proxies and caches tiles from multiple upstream sources. ATAK/iTAK clients fetch tiles from the server instead of hitting upstream tile providers directly.

**Benefits:**
- Avoids User-Agent blocking from OSM/OpenTopo tile servers (ATAK's User-Agent gets blocked)
- Caches tiles locally in MBTiles format for faster repeat access
- Single tile domain for all map sources — simplifies firewall rules
- Tiles older than 7 days are automatically refreshed on next request

### Architecture

```
ATAK/iTAK  →  tiles.cloudtak.<domain>:443 (nginx)
                    │
                    ▼
               MapProxy (gunicorn :8083)
               WMTS endpoint, MBTiles cache
                    │
                    ▼
          Upstream tile servers (OSM, ESRI, OpenTopo, OpenSeaMap)
```

### Tile Sources

| Layer | Upstream Source | Tile Format | Type |
|-------|---------------|-------------|------|
| `osm` | tile.openstreetmap.org | PNG | Basemap |
| `opentopo` | tile.opentopomap.org | PNG | Basemap |
| `esri_satellite` | server.arcgisonline.com World_Imagery | JPEG | Basemap |
| `esri_clarity` | clarity.maptiles.arcgis.com | JPEG | Basemap |
| `esri_topo` | server.arcgisonline.com World_Topo_Map | JPEG | Basemap |
| `openseamap_base` | tiles.openseamap.org (water) | PNG | Basemap |
| `openseamap_seamarks` | tiles.openseamap.org (seamarks) | PNG | Overlay |

### How It Works

1. **`setup-mapproxy.sh`** installs MapProxy 6.0.1 in a Python venv at `/opt/mapproxy/`, configures gunicorn (4 workers on port 8083), a systemd service, nginx WMTS proxy, and a Let's Encrypt cert for `tiles.cloudtak.<domain>`.

2. **`setup-maps.sh`** generates 7 MOBAC XML map source files pointing at the MapProxy WMTS URLs and uploads them as a data package to OTS via the API. ATAK/iTAK clients receive the data package on connection.

### WMTS vs TMS — Important

MapProxy serves tiles via **WMTS** (NW origin, Y from top), **not** TMS (SW origin, Y from bottom). ATAK uses XYZ tile URLs which expect NW origin — matching WMTS. Using TMS causes an Y-axis flip where tiles show the wrong geographic location.

The nginx proxy rewrites `/{layer}/{z}/{x}/{y}.{ext}` → `/wmts/{layer}/webmercator/{z}/{x}/{y}.{ext}`.

### Seeding (Pre-fill Cache)

The seed config covers Sweden (bbox `[10.5, 55.2, 24.2, 69.1]`) at zoom levels 0–14:

```bash
sudo /opt/mapproxy/venv/bin/mapproxy-seed \
  -f /opt/mapproxy/mapproxy.yaml \
  -s /opt/mapproxy/seed.yaml
```

### Cache Management

```bash
# Cache location
ls -lh /var/cache/mapproxy/

# Cache TTL: tiles older than 7 days re-fetched on next request
# (stale tile served immediately while fresh one is fetched in background)

# Clear all cached tiles for a fresh start
sudo rm /var/cache/mapproxy/*.mbtiles
sudo systemctl restart mapproxy
```

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/setup-mapproxy.sh` | Installs MapProxy, gunicorn, systemd, nginx, Let's Encrypt |
| `scripts/setup-maps.sh` | Generates MOBAC XML data package, uploads to OTS API |

Both are called automatically by `setup-all.sh` during deployment.

---

## ATAK Map Source XML Reference

ATAK uses `.xml` preference files to define custom map sources. Distribute these via data packages (Method 2) with `contentType="Preference File"`, or place them in `atak/maps/` on the device.

### XYZ/TMS Source

```xml
<?xml version="1.0" encoding="UTF-8"?>
<customMapSource>
    <name>OpenStreetMap</name>
    <minZoom>0</minZoom>
    <maxZoom>19</maxZoom>
    <tileType>png</tileType>
    <tileUpdate>None</tileUpdate>
    <url>https://tile.openstreetmap.org/{$z}/{$x}/{$y}.png</url>
    <backgroundColor>#000000</backgroundColor>
</customMapSource>
```

### WMS Source

```xml
<?xml version="1.0" encoding="UTF-8"?>
<customWmsMapSource>
    <name>Lantmäteriet Topographic (Overview)</name>
    <minZoom>0</minZoom>
    <maxZoom>14</maxZoom>
    <tileType>png</tileType>
    <url>https://minkarta.lantmateriet.se/map/topowebb</url>
    <layers>topowebbkartan</layers>
    <version>1.1.1</version>
    <coordinateSystem>EPSG:3857</coordinateSystem>
    <tileUpdate>None</tileUpdate>
    <backgroundColor>#000000</backgroundColor>
</customWmsMapSource>
```

### WMTS Source

```xml
<?xml version="1.0" encoding="UTF-8"?>
<customWmtsMapSource>
    <name>Lantmäteriet WMTS</name>
    <minZoom>0</minZoom>
    <maxZoom>15</maxZoom>
    <tileType>png</tileType>
    <url>https://minkarta.lantmateriet.se/map/topowebb/wmts</url>
    <layers>topowebb</layers>
    <style>default</style>
    <tileMatrixSet>3857</tileMatrixSet>
    <version>1.0.0</version>
</customWmtsMapSource>
```

### Key XML Fields

| Field | Description |
|-------|-------------|
| `name` | Display name in ATAK map selector |
| `url` | Tile URL with `{$z}/{$x}/{$y}` (XYZ) or WMS/WMTS base URL |
| `tileType` | Image format: `png`, `jpg` |
| `minZoom` / `maxZoom` | Zoom range |
| `layers` | WMS/WMTS layer name |
| `version` | `1.1.1` for WMS, `1.0.0` for WMTS |
| `coordinateSystem` | e.g. `EPSG:3857` |
| `serverParts` | Subdomains for load balancing: `a,b,c` |
| `tileUpdate` | `None`, `IfModified`, `Always` |
| `invertYCoordinate` | `true` for TMS sources |
| `backgroundColor` | Hex color for missing tiles |

### File Placement on Device

- Map source XMLs: `atak/maps/`
- Offline imagery: `atak/imagery/mobile/`
- KML/KMZ: imported via Import Manager or data package

---

## Ready-to-Use Map Sources

### OpenStreetMap (Free, No API Key)

Map Layers API:
```json
{
  "name": "OpenStreetMap",
  "type": "XYZ",
  "url": "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
  "tileType": "png",
  "minZoom": 0,
  "maxZoom": 19,
  "enabled": true
}
```

### ESRI World Imagery (Free for Display)

```json
{
  "name": "ESRI Satellite",
  "type": "XYZ",
  "url": "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
  "tileType": "jpg",
  "minZoom": 0,
  "maxZoom": 19,
  "enabled": true
}
```

Note: ESRI tile URL uses `{z}/{y}/{x}` order (y before x).

### ESRI World Topo Map

```json
{
  "name": "ESRI Topo",
  "type": "XYZ",
  "url": "https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}",
  "tileType": "jpg",
  "minZoom": 0,
  "maxZoom": 19,
  "enabled": true
}
```

### Lantmäteriet — Swedish Maps

Lantmäteriet open data is CC0 license (free for all use including commercial). API access requires a free account at [Geotorget](https://geotorget.lantmateriet.se/).

#### Topografisk webbkarta Visning, översiktlig (Free)

Small-scale topographic map, suitable for zoom levels below ~1:30,000. Available as a free open data WMTS/WMS viewing service.

```json
{
  "name": "Lantmäteriet Topo (Overview)",
  "type": "WMS",
  "url": "https://minkarta.lantmateriet.se/map/topowebb",
  "layers": "topowebbkartan",
  "version": "1.1.1",
  "coordinateSystem": "EPSG:3857",
  "tileType": "png",
  "minZoom": 0,
  "maxZoom": 14,
  "enabled": true,
  "ignoreErrors": true
}
```

> **Note:** The full-detail "Topografisk webbkarta Visning" and "cache" variants are paid services via Geotorget. Only the overview ("översiktlig") version is free.

#### Ortofoto historiska Visning (Free)

Historical aerial photos (1949–2005) in B/W, color, and IR. Free open data.

#### NMK50 / NMK250 — Nationell Militär Karta (Free Download)

Swedish military maps at 1:50,000 and 1:250,000 scale. Available as free downloadable georeferenced raster images via Geotorget. Excellent for offline use — download the rasters, convert to MBTiles, distribute via data packages.

- **NMK50**: Detailed field map with terrain, roads, buildings, elevation contours
- **NMK250**: Overview map with administrative boundaries, infrastructure

Download via Geotorget API (requires free account):
```bash
# After obtaining API token from geotorget.lantmateriet.se
# NMK50 and NMK250 are available as downloadable raster images
# Convert downloaded GeoTIFFs to MBTiles for ATAK/iTAK offline use
```

#### Important: Lantmäteriet Projection

Lantmäteriet native CRS is SWEREF99 TM (EPSG:3006). Always request in **EPSG:3857** for TAK compatibility. WMS requests handle this via the `coordinateSystem` parameter.

---

## Offline Tiles

For field use without connectivity, pre-download tiles as MBTiles (for ATAK/iTAK) or PMTiles (for CloudTAK).

### Creating MBTiles

#### QGIS (GUI)

1. Install QGIS
2. Add your source layer (WMS, OpenStreetMap, local raster)
3. Processing → Toolbox → "Generate XYZ tiles (MBTiles)"
4. Set extent, zoom range (e.g. 8–15), output file
5. Distribute the `.mbtiles` file via data package

#### MOBAC — Mobile Atlas Creator (GUI)

Free Java app supporting many online tile sources:
1. Download from https://mobac.sourceforge.io/
2. Select tile source, draw region, choose zoom levels
3. Export as MBTiles
4. Distribute via data package

#### MapProxy (Automated/Scripted)

```yaml
# mapproxy.yaml — example for caching Swedish topo tiles
sources:
  lantmateriet_topo:
    type: wms
    req:
      url: https://minkarta.lantmateriet.se/map/topowebb
      layers: topowebbkartan
    supported_srs: ['EPSG:3857']

caches:
  topo_cache:
    grids: [webmercator]
    sources: [lantmateriet_topo]
    cache:
      type: mbtiles
      filename: /data/sweden-topo.mbtiles

seeds:
  sweden_seed:
    caches: [topo_cache]
    levels:
      to: 15
    coverages:
      sweden:
        bbox: [10.5, 55.2, 24.2, 69.1]
        srs: "EPSG:4326"
```

```bash
# Run the seeder
docker run -v $(pwd):/mapproxy -v /data:/data mapproxy/mapproxy \
  mapproxy-seed -f /mapproxy/mapproxy.yaml -s /mapproxy/seed.yaml
```

#### GeoTIFF → MBTiles via GDAL

```bash
# Convert downloaded Lantmäteriet NMK rasters to MBTiles
gdal_translate -of MBTiles input.tif output.mbtiles
gdaladdo -r average output.mbtiles 2 4 8 16  # Build overview levels
```

### Converting MBTiles → PMTiles (for CloudTAK)

```bash
# Install pmtiles CLI
go install github.com/protomaps/go-pmtiles/cmd/pmtiles@latest

# Convert
pmtiles convert input.mbtiles output.pmtiles

# Or via npm
npx pmtiles convert input.mbtiles output.pmtiles
```

### Size Considerations

- TAK Server default upload limit is **400MB** for data packages (`/files/api/config`)
- MBTiles files >2GB can be slow to import on mobile devices
- Consider splitting by region or zoom level for large areas
- For large tile sets, host on a tile server (CloudTAK PMTiles, TileServer GL) instead of distributing as data packages

---

## Data Overlays

### KML/KMZ

The most widely supported overlay format across ATAK, iTAK, and CloudTAK.

**Via data package:**
```xml
<Content ignore="false" zipEntry="overlays/boundaries.kml">
    <Parameter name="contentType" value="KML"/>
</Content>
```

**Via mission content:**
```bash
# Upload KML to a mission
curl -k --cert admin.pem \
  -X PUT \
  -F "resource=@boundaries.kml" \
  "https://${TAK_DOMAIN}:8443/Marti/api/missions/${MISSION_NAME}/contents?uid=kml-boundaries"
```

**Export mission as KML:**
```bash
curl -k --cert admin.pem \
  "https://${TAK_DOMAIN}:8443/Marti/api/missions/${MISSION_NAME}/kml"
```

Supports: Placemarks, Paths, Polygons, Ground Overlays, Network Links.

### GeoJSON

- **CloudTAK**: Native import via Imports tool in the web UI
- **ATAK**: Limited native support — convert to KML for best compatibility:
  ```bash
  ogr2ogr -f KML output.kml input.geojson
  ```

### GPX

GPS tracks and waypoints. Import directly in ATAK/iTAK or distribute via data package.

### Shapefiles

Convert before distributing:
```bash
# To KML (for ATAK/iTAK)
ogr2ogr -f KML output.kml input.shp

# To GeoPackage (for ATAK)
ogr2ogr -f "GPKG" output.gpkg input.shp
```

---

## Automation Scripts (OTS Deployment)

The OTS deployment automates map source distribution via two scripts in `ots/scripts/`:

### setup-mapproxy.sh

Installs MapProxy as a tile cache proxy. See [Method 4: MapProxy Tile Cache](#method-4-mapproxy-tile-cache-ots-deployment) for details.

### setup-maps.sh

Generates a data package with 7 MOBAC XML map source files pointing at the MapProxy WMTS URLs on `tiles.cloudtak.<domain>`, then uploads it to OTS via the API on port 8081. Clients receive the data package on connection.

### build-maps-package.sh (Local Build)

The `maps/` directory contains the same XML files for local building:

```bash
cd maps
./build-maps-package.sh
# Creates maps-package.zip in the current directory
```

### Map Layers API (Official TAK Server Only)

For the official TAK Server (not OTS), use the Map Layers API instead of data packages. See [Method 1](#method-1-map-layers-api-official-tak-server).

---

## Gotchas & Compatibility Notes

| Issue | Details |
|-------|---------|
| **TMS vs XYZ Y-axis** | TMS has inverted Y coordinates. Use `invertYCoordinate=true` in map source XML, or `"invertYCoordinate": true` in the JSON. Most modern tile sources (OSM, ESRI) use XYZ (non-inverted). |
| **WMS version axis order** | WMS 1.1.1 uses `x,y` (lon,lat). WMS 1.3.0 swaps to `y,x` (lat,lon). Use `1.1.1` to avoid projection issues. |
| **HTTPS required** | ATAK and iTAK may reject HTTP tile URLs. Use HTTPS for all tile sources. |
| **iTAK format limitations** | iTAK supports fewer formats than ATAK. For cross-compatibility, stick to: MBTiles, GeoPackage, KML/KMZ, GPX. No Shapefiles, NITF, MrSID. |
| **MBTiles vs PMTiles** | ATAK/iTAK use MBTiles for offline tiles. CloudTAK uses PMTiles. They are different formats for different clients. |
| **Upload size limit** | TAK Server default upload limit is 400MB for data packages. Check/change via `/files/api/config`. |
| **Large MBTiles** | Files >2GB are slow to import on mobile. Split by region or zoom level, or use a tile server instead. |
| **Lantmäteriet CRS** | Native CRS is SWEREF99 TM (EPSG:3006). Always request in EPSG:3857 for TAK. |
| **Lantmäteriet API access** | Free Geotorget account required for API tokens. Some products (detailed topo, ortofoto viewing) are paid. Overview topo map and download products (NMK, vector data) are free. |
| **CORS for CloudTAK tiles** | CloudTAK tile server needs proper CORS headers. The Caddy/nginx reverse proxy in our deployment handles this. |
| **Map Layers API vs Data Packages** | Map Layers API is real-time and updateable (add/remove layers anytime). Data packages are one-time downloads. Use Map Layers for online sources, data packages for offline tiles. |
| **OTS lacks Map Layers API** | OpenTAK Server does not implement `/Marti/api/maplayers`. Use data packages with map source XMLs instead. |
| **ESRI tile URL order** | ESRI uses `{z}/{y}/{x}` (y before x), unlike OSM which uses `{z}/{x}/{y}`. |
| **ATAK map source XML variables** | ATAK XML uses `{$z}/{$x}/{$y}` (with dollar signs). Map Layers API JSON uses `{z}/{x}/{y}` (without dollar signs). |
