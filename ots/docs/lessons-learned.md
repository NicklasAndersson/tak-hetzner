# Lessons Learned — CloudTAK + OTS Deployment

Samlade erfarenheter från driftsättning av OpenTAK Server + CloudTAK (april 2026).

---

## 1. OTS certifikat: .pem och .nopass.key matchar INTE

**Problem:** Filerna `administrator.pem` och `administrator.nopass.key` i
`~/ots/ca/certs/<user>/` har olika modulus — de hör inte ihop. curl med
`--cert`/`--key` mot 8443 misslyckas med SSL-handshake.

**Orsak:** OTS cert-regenerering skriver bara över vissa filer. Den enda källan
till ett konsistent cert+nyckel-par är `.p12`-filen.

**Lösning:** Extrahera alltid från `.p12` med `-legacy`-flaggan (krävs för
OpenSSL 3.x):

```bash
openssl pkcs12 -in user.p12 -clcerts -nokeys -passin pass:atakatak -legacy -out cert.pem
openssl pkcs12 -in user.p12 -nocerts -nodes -passin pass:atakatak -legacy -out key.pem
```

**Verifiera att de matchar:**
```bash
openssl x509 -noout -modulus -in cert.pem | openssl md5
openssl rsa -noout -modulus -in key.pem | openssl md5
# Samma hash = OK
```

**OBS:** Extraherade PEM-filer innehåller "Bag Attributes"-headers som måste
strippas innan de skickas till CloudTAK API. Regex:
`-----BEGIN CERTIFICATE-----...-----END CERTIFICATE-----`

---

## 2. CloudTAK API_URL — intern vs publik URL

**Problem:** Login fungerar men kartan laddar inte. Inga tile-requests syns i
API-loggen. Webbläsarens nätverksflik visar inga bildrequests alls.

**Rotorsak:** `API_URL=http://api:5000` i `.env` → CloudTAK genererar TileJSON
med tile-URL:er som pekar på den interna Docker-adressen (`http://api:5000/...`).
Webbläsaren kan inte nå Docker-interna hostnamn.

**Kod:** `api/lib/interface-basemap.ts:168` använder `config.API_URL` för att
bygga tile-URL:er som skickas till webbläsaren.

**Lösning:**
- `.env`: `API_URL=https://<CLOUDTAK_DOMAIN>` (publik URL, för webbläsaren)
- `docker-compose.yml`: Hårdkoda `API_URL=http://api:5000` i environment för
  **events** och **media** (de behöver intern Docker-adress)
- API-tjänsten använder `${API_URL}` från `.env` (publika URL:en)

```yaml
# docker-compose.yml — events service
environment:
    - API_URL=http://api:5000   # Hårdkodad, INTE ${API_URL}

# docker-compose.yml — api service
environment:
    - API_URL=${API_URL}        # Från .env = https://cloudtak.domain.se
```

**Diagnostik:** Hämta TileJSON och granska `tiles`-arrayen:
```bash
TOKEN=$(curl -s -X POST http://localhost:5000/api/login \
  -H "Content-Type: application/json" \
  -d '{"username":"administrator","password":"..."}' | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

curl -s "http://localhost:5000/api/basemap/2/tiles?token=$TOKEN" | python3 -m json.tool
# tiles[0] ska börja med https://cloudtak.domain.se/..., INTE http://api:5000/...
```

---

## 3. NODE_TLS_REJECT_UNAUTHORIZED krävs

**Problem:** CloudTAK API kan inte ansluta till OTS (TLS-handshake misslyckas).
Loggar visar `ERR_TLS_CERT_ALTNAME_INVALID`.

**Orsak:** OTS server-cert har `CN=opentakserver, SAN=DNS:opentakserver` — det
innehåller INTE det faktiska domännamnet (t.ex. `tak.example.se`).

**Lösning:** Lägg till i API-containerns environment i `docker-compose.yml`:
```yaml
- NODE_TLS_REJECT_UNAUTHORIZED=0
```

---

## 4. PostGIS Docker-volym saknas (DB töms vid restart)

**Problem:** All konfiguration (server, connections, basemaps, profiler)
försvinner efter `docker compose down`.

**Orsak:** Default `docker-compose.yml` har ingen volym för postgis-containern.

**Lösning:**
```yaml
# Under postgis-tjänsten:
    postgis:
        volumes:
            - cloudtak-pgdata:/var/lib/postgresql/data

# Top-level:
volumes:
    cloudtak-pgdata:
```

**OBS:** Efter att volymen lagts till och postgis återskapats är databasen tom.
Kör `PATCH /api/server` och `POST /api/connection` igen.

---

## 5. Server URL-protokoll: ssl:// inte https://

**Problem:** CloudTAK ansluter till OTS men CoT-streaming fungerar inte.
Connection-status visar "dead".

**Lösning:** `PATCH /api/server` ska ha:
- `url`: `ssl://<OTS_DOMAIN>:8089` (CoT-streaming, TAK-protokollet)
- `api`: `https://<OTS_DOMAIN>:8443` (Marti REST API)

`https://` fungerar inte för CoT-porten (8089). Protokollet måste vara `ssl://`.

---

## 6. Connection-status "dead" är kosmetiskt

**Problem:** CloudTAK visar connection-status "dead" trots att kanaler
uppdateras och CoT-meddelanden flödar.

**Orsak:** OTS ekar tillbaka CoT-ping (`t-x-c-t`) med samma typ istället för
pong-svar (`t-x-c-t-r`). CloudTAK väntar på `t-x-c-t-r` för att sätta
`open=true`.

**Åtgärd:** Ignorera. Statusen är kosmetisk — kanaler och data fungerar.

---

## 7. Webbläsare med expired/stale tokens

**Problem:** WebSocket-reconnect varje sekund, massor av 401-svar i API-loggen.

**Orsak:** Webbläsare (särskilt Firefox) cachar JWT-tokens aggressivt. Om
servern startas om eller tokensigneringen ändras blir cachade tokens ogiltiga
men webbläsaren fortsätter använda dem.

**Lösning:** Stäng alla flikar till CloudTAK och logga in på nytt. Alternativt
hard-refresh (Cmd+Shift+R / Ctrl+Shift+R).

---

## 8. OTS Maps-uppladdning: hash=auto fungerar inte

**Problem:** Uppladdning av data packages med `hash=auto` i URL:en skapar
trasiga poster i databasen. Filen kan inte laddas ned efteråt.

**Lösning:** Beräkna SHA256-hash innan uppladdning:
```bash
HASH=$(sha256sum sweden-maps.zip | cut -d" " -f1)
curl -F "assetfile=@sweden-maps.zip" \
  "http://localhost:8081/Marti/sync/missionupload?hash=${HASH}&filename=sweden-maps.zip&creatorUid=admin"
```

Använd port 8081 (HTTP) istället för 8443 (HTTPS mTLS) — undviker
cert-mismatch-problem.

---

## 9. MapProxy: TMS vs XYZ koordinater

**Problem:** MapProxy-tiles via TMS visar fel del av världen jämfört med
direkta tile-requests till upstream-källor.

**Orsak:** TMS använder omvänd Y-axel jämfört med XYZ (Slippy Map). Google/OSM
XYZ `y=300` → TMS `y=1023-300=723` vid zoom 10.

**Lösning:** Nginx rewrite-regler konverterar XYZ-URL:er (som ATAK/iTAK
förväntar) till TMS-format:
```nginx
location ~ ^/osm/(\d+)/(\d+)/(\d+)\.png$ {
    set $z $1;
    set $x $2;
    set $y $3;
    set_by_lua_block $tms_y {
        return math.pow(2, tonumber(ngx.var.z)) - 1 - tonumber(ngx.var.y)
    }
    proxy_pass http://127.0.0.1:8083/tms/1.0.0/osm/webmercator/$z/$x/$tms_y.png;
}
```

---

## 10. MapProxy: Lantmäteriet WMS kräver meta_size [1,1]

**Problem:** Lantmäteriet-tiles returneras som felmeddelanden eller är tomma.

**Orsak:** Default MapProxy hämtar meta-tiles (flera tiles i en stor request)
men Lantmäteriets WMS klarar inte stora bounding boxes.

**Lösning:** I `mapproxy.yaml`, lägg till under lantmäteriet-cachen:
```yaml
lantmateriet_cache:
    sources: [lantmateriet]
    grids: [webmercator]
    meta_size: [1, 1]
    meta_buffer: 0
    cache:
        type: mbtiles
        filename: /var/cache/mapproxy/lantmateriet.mbtiles
```

---

## Sammanfattning: Checklista vid ny deploy

1. Extrahera cert/nyckel från `.p12` med `-legacy`, inte `.pem`/`.nopass.key`
2. Sätt `API_URL=https://<CLOUDTAK_DOMAIN>` i `.env`
3. Hårdkoda `API_URL=http://api:5000` för events/media i docker-compose.yml
4. Lägg till `NODE_TLS_REJECT_UNAUTHORIZED=0` i API-containern
5. Lägg till Docker-volym för postgis
6. Använd `ssl://` (inte `https://`) för server URL i `PATCH /api/server`
7. Beräkna SHA256-hash vid maps-uppladdning (inte `hash=auto`)
8. Konfigurera `meta_size: [1,1]` för Lantmäteriet i MapProxy
