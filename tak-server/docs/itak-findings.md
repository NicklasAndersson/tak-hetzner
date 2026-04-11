# iTAK Connection Issue — Findings

## Problem

iTAK fails to connect to TAK Server with a "generic error". The server logs show a **connect-disconnect loop**: subscriptions are added and immediately removed (~30ms) every ~15 seconds.

```
2026-04-03-08:43:24.901 Added Subscription: id=tls:564 source=78.66.250.176
2026-04-03-08:43:24.929 Removed Subscription: tls:564
```

The subscription IDs increment rapidly (500+ in an hour), confirming iTAK is retrying continuously.

## Server Configuration

- TAK Server 5.6-RELEASE-22 (Docker)
- Domain: `tak.hv-sog.se`, IP: `89.167.107.226`
- Port 8089: `<input _name="stdssl" protocol="tls" port="8089" coreVersion="2"/>` — mTLS (default `auth="x509"`)
- Port 8090: `<input _name="stdssl_auth" protocol="tls" port="8090" auth="file" coreVersion="2"/>` — username/password auth
- Global TLS keystore: `letsencrypt.jks` (Let's Encrypt cert, trusted by iOS)
- Global TLS truststore: `truststore-root.jks` (TAK CA, for client cert validation)

## Findings

### 1. TLS Handshake Succeeds

Tested from the server with no client certificate:

```
echo | openssl s_client -connect localhost:8090
subject=CN = tak.hv-sog.se
issuer=C = US, O = Let's Encrypt, CN = R12
Verify return code: 0 (ok)
```

The LE cert is served correctly. iOS trusts it. The subscription being "Added" in logs confirms iTAK completes the TLS handshake.

### 2. Disconnect Happens at TAK Protocol Level

The ~30ms gap between "Added" and "Removed" rules out a TLS handshake failure. The connection is established, then dropped during TAK protocol negotiation.

### 3. No Auth Error Messages in Logs

There are **no** "Invalid password", "authentication failed", or "FileAuth" errors anywhere in the messaging or API logs for the user's IP (78.66.250.176). This means the server likely isn't even reaching the password check.

### 4. PEER_DID_NOT_RETURN_A_CERTIFICATE Errors Exist (Different Source)

```
2026-04-03-08:44:22.960 ERROR NioNettyServerHandler error.
Cause: PEER_DID_NOT_RETURN_A_CERTIFICATE
Remote address: 172.18.0.1; Remote port: 59668; Local port: 8090
```

These errors come from `172.18.0.1` (Docker bridge network), **not** from the user's IP. They may be from internal health checks or a different connection path.

### 5. XSD Analysis — `input` vs `connector` Element

From `/opt/tak/CoreConfig.xsd`:

| Feature | `<connector>` (HTTPS) | `<input>` (streaming) |
|---------|----------------------|----------------------|
| `clientAuth` attribute | **Yes** (default `"true"`) | **No** |
| `keystoreFile` attribute | **Yes** | **No** |
| `auth` attribute | No | **Yes** (`authType`, default `"x509"`) |
| TLS config | Own `keystoreFile`/`keystorePass` | Shared global `<tls>` element |

**Key insight**: The `<input>` element has **no** `clientAuth` attribute. All streaming inputs share the single global `<tls>` element, which includes `truststoreFile` for client cert validation.

### 6. The Global Truststore Problem

The global TLS config applies to ALL streaming inputs:

```xml
<tls keystore="JKS" keystoreFile="certs/files/letsencrypt.jks"
     keystorePass="atakatak-hv-sog"
     truststore="JKS" truststoreFile="/opt/tak/certs/files/truststore-root.jks"
     truststorePass="atakatak-hv-sog"
     context="TLSv1.2" keymanager="SunX509"/>
```

The truststore is configured, which means the TLS layer **may** be configured to request client certificates. However, since the `openssl s_client` test (without client cert) succeeds and subscriptions are "Added", the server appears to accept connections without client certs.

### 7. `auth="file"` Behavior

The `auth="file"` attribute means TAK protocol-level authentication via `UserAuthenticationFile.xml` (username/password). This is separate from TLS mutual authentication.

With `auth="file"`, the expected flow is:
1. TLS handshake (server cert only, no client cert required)
2. TAK protocol negotiation
3. Client sends username/password via TAK protocol
4. Server validates against `UserAuthenticationFile.xml`

## Hypotheses

### H1: iTAK Not Sending Credentials Correctly (Most Likely)

iTAK connects, TLS succeeds, but iTAK may:
- Not be sending username/password at the TAK protocol level
- Be sending credentials in a format the server doesn't expect
- Be expecting a different authentication handshake (e.g., certificate-based)

The QR code format `Name - tak.hv-sog.se,tak.hv-sog.se,8090,ssl` may not carry username/password information, requiring manual entry in iTAK.

### H2: iTAK Doesn't Support `auth="file"` on Streaming Ports

iTAK may only support:
- Certificate-based auth (mTLS) on streaming ports
- Username/password auth only via the enrollment/provisioning flow (not streaming)

If iTAK needs a client certificate to maintain a streaming connection, `auth="file"` alone won't work.

### H3: Protocol Version Mismatch

The `coreVersion="2"` attribute is set. iTAK may expect a different protocol version or negotiation sequence.

### H4: Missing `authRequired` Attribute

The XSD shows an `authRequired` attribute (default `false`) on inputs. The current config doesn't set it explicitly. This might affect how the server handles the auth handshake.

## Potential Fixes to Try

1. **Import client certificate into iTAK** — Use the data package from ATAK enrollment (`tak://` URL) or manually import the `.p12` file. Connect to port 8089 (mTLS) instead of 8090.

2. **Try iTAK's built-in server connection UI** — Instead of QR code, manually configure the server in iTAK with host, port, and credentials.

3. **Check iTAK version** — Ensure latest version is installed; older versions may not support `auth="file"`.

4. **Enable DEBUG logging** on the TAK server messaging process to see exactly what happens during the TAK protocol negotiation:
   ```
   docker exec takserver bash -c "echo '--logging.level.com.bbn.marti=DEBUG' >> /opt/tak/messaging-readiness.sh"
   ```

5. **Try `authRequired="true"`** on the port 8090 input to explicitly signal auth requirement:
   ```xml
   <input _name="stdssl_auth" protocol="tls" port="8090" auth="file" authRequired="true" coreVersion="2"/>
   ```

6. **Test with ATAK on port 8090** — Configure ATAK to use port 8090 with username/password to isolate whether it's an iTAK-specific issue or a server config issue.

## Resolution

### Root Cause: TLS Mutual Auth Required on ALL Streaming Inputs

After enabling DEBUG logging and testing with user IP `213.113.121.140`, the server logs revealed:

```
2026-04-06-12:37:16.634 ERROR NioNettyServerHandler error.
Cause: PEER_DID_NOT_RETURN_A_CERTIFICATE
Remote address: 213.113.121.140; Remote port: 61672; Local port: 8090
```

**The TLS layer enforces mutual authentication (client cert required) on ALL streaming inputs**, regardless of the `auth="file"` setting. The `auth` attribute only controls application-level authentication — the underlying TLS layer still requires a client certificate because the global `<tls>` element has a truststore configured. The `<input>` XSD has no `clientAuth` attribute to disable this (only `<connector>` does).

This means `auth="file"` on a streaming port is effectively **useless without also providing a client certificate**. The earlier "Added/Removed" subscription loop (Finding #2) was likely a different manifestation of the same issue — connections from Docker bridge IP `172.18.0.1`.

### Solution: Client Certificates + mTLS on Port 8089

Since `auth="file"` cannot bypass TLS mutual auth, the solution is to use client certificates and connect via port 8089 (mTLS).

**Steps:**

1. Generate client cert on the server:
   ```bash
   docker exec -e STATE=SE -e CITY=Stockholm -e ORGANIZATIONAL_UNIT=TAK \
     -e ORGANIZATION=TAK -e CAPASS=atakatak-hv-sog -e PASS=atakatak-hv-sog \
     takserver bash -c "cd /opt/tak/certs && ./makeCert.sh client <username>"
   ```

2. Authorize the cert:
   ```bash
   docker exec takserver java -jar /opt/tak/utils/UserManager.jar \
     certmod -A /opt/tak/certs/files/<username>.pem
   ```

3. Copy cert from container:
   ```bash
   docker cp takserver:/opt/tak/certs/files/<username>.p12 /tmp/<username>.p12
   docker cp takserver:/opt/tak/certs/files/ca.pem /tmp/ca.pem
   ```

4. **Re-export p12 with iOS-compatible encryption** (see below), then package into a TAK data package (.zip).

### iOS P12 Compatibility Issue

TAK Server's `makeCert.sh` uses OpenSSL with legacy encryption (`pbeWithSHA1And40BitRC2-CBC`). **iOS/iTAK cannot load these p12 files** — you get "failed to load certificate".

The fix is to re-export the p12 with modern AES encryption:

```bash
# Extract cert and key from legacy p12 (requires -provider legacy on OpenSSL 3.x)
openssl pkcs12 -in <user>.p12 -out /tmp/cert.pem -clcerts -nokeys \
  -passin pass:<password> -provider legacy -provider default

openssl pkcs12 -in <user>.p12 -out /tmp/key.pem -nocerts -nodes \
  -passin pass:<password> -provider legacy -provider default

# Re-export with iOS-compatible encryption
openssl pkcs12 -export \
  -in /tmp/cert.pem -inkey /tmp/key.pem \
  -CAfile ca.pem -chain \
  -out <user>-ios.p12 -name <user> \
  -passout pass:<password> \
  -certpbe AES-256-CBC -keypbe AES-256-CBC -macalg sha256

# Also re-export CA truststore for iOS
openssl pkcs12 -export -nokeys \
  -in ca.pem -out truststore-root-ios.p12 -name truststore-root \
  -passout pass:<password> \
  -certpbe AES-256-CBC -macalg sha256
```

**Why this happens:** OpenSSL 3.x defaults to legacy PKCS#12 encryption for compatibility with Java keystores, but iOS requires modern algorithms (AES-256-CBC). The `-certpbe` and `-keypbe` flags override the encryption, and `-macalg sha256` replaces the legacy SHA1 MAC.

### iTAK Data Package Format

iTAK imports server connections via a `.zip` data package containing:

```
<username>-datapackage.zip
├── certs/<username>.p12          # iOS-compatible client cert
├── certs/truststore-root.p12     # iOS-compatible CA truststore
├── <username>.pref               # Connection preferences XML
└── MANIFEST/manifest.xml         # Package manifest
```

The `.pref` file configures the server connection:

```xml
<?xml version="1.0" standalone="yes"?>
<preferences>
    <preference version="1" name="cot_streams">
        <entry key="count" class="class java.lang.Integer">1</entry>
        <entry key="description0" class="class java.lang.String">TAK Server</entry>
        <entry key="enabled0" class="class java.lang.Boolean">true</entry>
        <entry key="connectString0" class="class java.lang.String">tak.hv-sog.se:8089:ssl</entry>
    </preference>
    <preference version="1" name="com.atakmap.app_preferences">
        <entry key="clientPassword" class="class java.lang.String">CERT_PASSWORD</entry>
        <entry key="caPassword" class="class java.lang.String">CA_PASSWORD</entry>
        <entry key="certificateLocation" class="class java.lang.String">/cert/USERNAME.p12</entry>
        <entry key="caLocation" class="class java.lang.String">/cert/truststore-root.p12</entry>
    </preference>
</preferences>
```

Transfer the .zip to iPhone via AirDrop/email, then open with iTAK.

## Key Takeaways

1. **`auth="file"` does NOT disable TLS mutual auth on streaming inputs.** Client certs are always required on `<input>` elements when the global `<tls>` has a truststore. Only `<connector>` elements have a `clientAuth` attribute.

2. **TAK Server's makeCert.sh produces p12 files incompatible with iOS.** Always re-export with `-certpbe AES-256-CBC -keypbe AES-256-CBC -macalg sha256` for iTAK/iOS.

3. **OpenSSL 3.x on macOS needs `-provider legacy -provider default`** to read the legacy p12 files from the server.

4. **Port 8090 (auth="file") is effectively unusable for iTAK without client certs.** Consider removing it or keeping it only for ATAK clients that have client certs but also need password auth.

---

## Detailed Attempt Log

### Attempt 1: Username/Password Auth via QR Code (Port 8090)

**Date:** 2026-04-03
**Approach:** Configure port 8090 with `auth="file"` for username/password authentication, generate iTAK QR codes pointing at `tak.hv-sog.se:8090:ssl`.

**Steps taken:**
1. Added `<input _name="stdssl_auth" protocol="tls" port="8090" auth="file" coreVersion="2"/>` to CoreConfig.xml
2. Added port 8090 to docker-compose.yml port mappings
3. Opened UFW firewall for 8090/tcp
4. Restarted TAK Server container
5. Generated QR codes pointing to `tak.hv-sog.se:8090:ssl` with username/password

**Result:** iTAK showed a **connect-disconnect loop**. Server logs showed subscriptions being added and immediately removed every ~15 seconds:
```
Added Subscription: id=tls:564 source=78.66.250.176
Removed Subscription: tls:564 (30ms later)
```

**Why it failed:** The TLS layer requires mutual auth (client certificate) on ALL streaming `<input>` ports when the global `<tls>` element has a truststore configured. The `<input>` XSD has no `clientAuth` attribute to disable this. `auth="file"` only controls application-level auth, not TLS mutual auth.

---

### Attempt 2: Add `authRequired="true"` + DEBUG Logging (Port 8090)

**Date:** 2026-04-06
**Approach:** Add explicit `authRequired="true"` to port 8090 input and enable DEBUG logging to see exactly what's happening.

**Steps taken:**
1. Modified port 8090 input: `<input _name="stdssl_auth" protocol="tls" port="8090" auth="file" authRequired="true" coreVersion="2"/>`
2. Added DEBUG loggers to `logging-restrictsize.xml`:
   - `com.bbn.marti.nio` (level=debug)
   - `com.bbn.marti.service.SubscriptionManager` (level=debug)
   - `com.bbn.marti.groups` (level=debug)
   - `com.bbn.marti.util.spring` (level=debug)
3. Copied logging config into container and restarted

**Result:** DEBUG logs revealed the definitive error. For the user's IP:
```
2026-04-06-12:37:16.634 ERROR NioNettyServerHandler error.
Cause: PEER_DID_NOT_RETURN_A_CERTIFICATE
Remote address: 213.113.121.140; Remote port: 61672; Local port: 8090
```

**Why it failed:** Same root cause — TLS layer demands client certificate before the connection even reaches the application auth layer. `authRequired="true"` had no effect on TLS-level behavior.

---

### Attempt 3: Client Certificate via Data Package (Port 8089, Legacy P12)

**Date:** 2026-04-06
**Approach:** Accept that mTLS is required. Generate client certificate, package into iTAK data package, connect via port 8089.

**Steps taken:**
1. Generated `itakuser1` client cert on server using `makeCert.sh`:
   ```bash
   docker exec -e STATE=SE -e CITY=Stockholm -e ORGANIZATIONAL_UNIT=TAK \
     -e ORGANIZATION=TAK -e CAPASS=atakatak-hv-sog -e PASS=atakatak-hv-sog \
     takserver bash -c "cd /opt/tak/certs && ./makeCert.sh client itakuser1"
   ```
2. Authorized cert: `UserManager.jar certmod -A /opt/tak/certs/files/itakuser1.pem`
3. Downloaded `itakuser1.p12` and `ca.pem` from server
4. Created `truststore-root.p12` from `ca.pem` using OpenSSL
5. Built data package zip with .pref file pointing to `tak.hv-sog.se:8089:ssl`
6. AirDropped zip to iPhone, opened with iTAK

**Result:** iTAK showed **"failed to load certificate"** during import.

**Why it failed:** `makeCert.sh` uses OpenSSL with legacy PKCS#12 encryption (`pbeWithSHA1And40BitRC2-CBC, Iteration 2048`). iOS/iTAK cannot read this encryption format — it only supports modern algorithms like AES-256-CBC.

**Diagnostic command that confirmed the issue:**
```bash
openssl pkcs12 -in itakuser1.p12 -info -nokeys -passin pass:atakatak-hv-sog
# Output showed: pbeWithSHA1And40BitRC2-CBC, Iteration 2048
# And: Error outputting keys and certificates: RC2-40-CBC unsupported
```

---

### Attempt 4: iOS-Compatible P12 Re-export (AES-256-CBC)

**Date:** 2026-04-06
**Approach:** Extract cert+key from legacy p12, re-export with iOS-compatible AES-256-CBC encryption.

**Steps taken:**
1. Extracted cert from legacy p12 (requires legacy provider on OpenSSL 3.x):
   ```bash
   openssl pkcs12 -in itakuser1.p12 -out /tmp/itakuser1-cert.pem -clcerts -nokeys \
     -passin pass:atakatak-hv-sog -provider legacy -provider default
   ```
2. Extracted key:
   ```bash
   openssl pkcs12 -in itakuser1.p12 -out /tmp/itakuser1-key.pem -nocerts -nodes \
     -passin pass:atakatak-hv-sog -provider legacy -provider default
   ```
3. Re-exported client cert with AES-256-CBC:
   ```bash
   openssl pkcs12 -export \
     -in /tmp/itakuser1-cert.pem -inkey /tmp/itakuser1-key.pem \
     -CAfile ca.pem -chain \
     -out itakuser1-ios.p12 -name itakuser1 \
     -passout pass:atakatak-hv-sog \
     -certpbe AES-256-CBC -keypbe AES-256-CBC -macalg sha256
   ```
4. Re-exported CA truststore with AES-256-CBC:
   ```bash
   openssl pkcs12 -export -nokeys \
     -in ca.pem -out truststore-root-ios.p12 -name truststore-root \
     -passout pass:atakatak-hv-sog \
     -certpbe AES-256-CBC -macalg sha256
   ```
5. Rebuilt data package zip using iOS-compatible files:
   - `certs/itakuser1.p12` (3750 bytes, AES-256-CBC)
   - `certs/truststore-root.p12` (1219 bytes, AES-256-CBC)
   - `itakuser1.pref` (924 bytes)
   - `MANIFEST/manifest.xml` (470 bytes)
   - Total zip: 5908 bytes

**Initial problem:** First rebuild produced a 22-byte zip because the iOS p12 files were in the parent directory (`/Users/nicklas/dev/tak/`) but the script ran from `tak-server/` subdirectory with relative paths. Fixed by using `../itakuser1-ios.p12` paths.

**Result:** Data package imported into iTAK. **Import succeeded (certificate loaded)**, but **connection still fails** — iTAK shows "failed import" or connection error. No connection attempt visible in server logs from user IP 213.113.121.140.

**Status:** Under investigation. Possible issues:
- `.pref` file format may not be fully compatible with iTAK (originally ATAK format)
- iTAK may need different preference keys than ATAK
- The data package may import correctly but not auto-configure the server connection
- iTAK may require the connection to be configured manually after importing certs

---

### Data Package Structure (Current)

```
itakuser1-datapackage.zip (5908 bytes)
├── certs/itakuser1.p12          # 3750 bytes — iOS-compatible, AES-256-CBC
├── certs/truststore-root.p12    # 1219 bytes — iOS-compatible, AES-256-CBC
├── itakuser1.pref               # 924 bytes — connection config
└── MANIFEST/manifest.xml        # 470 bytes — package manifest
```

**.pref file:**
```xml
<?xml version="1.0" standalone="yes"?>
<preferences>
    <preference version="1" name="cot_streams">
        <entry key="count" class="class java.lang.Integer">1</entry>
        <entry key="description0" class="class java.lang.String">TAK Server HV-SOG</entry>
        <entry key="enabled0" class="class java.lang.Boolean">true</entry>
        <entry key="connectString0" class="class java.lang.String">tak.hv-sog.se:8089:ssl</entry>
    </preference>
    <preference version="1" name="com.atakmap.app_preferences">
        <entry key="clientPassword" class="class java.lang.String">atakatak-hv-sog</entry>
        <entry key="caPassword" class="class java.lang.String">atakatak-hv-sog</entry>
        <entry key="certificateLocation" class="class java.lang.String">/cert/itakuser1.p12</entry>
        <entry key="caLocation" class="class java.lang.String">/cert/truststore-root.p12</entry>
    </preference>
</preferences>
```

### Next Steps to Investigate

1. **Check if iTAK uses a different .pref format** — iTAK may use different preference names than ATAK (e.g., different key names for cert paths)
2. **Try importing cert files manually in iTAK** — Instead of data package, import the .p12 files directly via iTAK settings, then manually configure the server connection
3. **Try `.itak` file extension** — Some reports suggest iTAK expects `.itak` extension instead of `.zip`
4. **Check iTAK version compatibility** — Ensure latest iTAK version is installed
5. **Try ATAK on Android as control test** — Verify the data package works with ATAK to isolate whether it's an iTAK-specific format issue

## References

- CoreConfig.xsd: `input` type at line 1382, `authType` at line 1391
- TAK Server source: https://github.com/TAK-Product-Center/Server
- XSD `connector` type has `clientAuth` (line 72); `input` does NOT
- OpenSSL PKCS#12 encryption: https://www.openssl.org/docs/man3.0/man1/openssl-pkcs12.html
