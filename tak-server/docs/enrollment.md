# User Provisioning (ATAK + iTAK)

Bulk-create TAK Server users and generate enrollment artifacts for both **ATAK**
(Android) and **iTAK** (iOS). Based on
[TAK-mass-enrollment](https://github.com/sgofferj/TAK-mass-enrollment).

## How it works

The provisioning script runs entirely on the server:

1. **Creates users** via the TAK Server API (port 8443) using the admin cert
2. **Generates client certificates** (`makeCert.sh client <user>`)
3. **Authorizes certificates** (`UserManager.jar certmod -A`)
4. **Re-exports P12 for iOS** — TAK Server produces legacy RC2-40-CBC P12 files
   that iOS cannot read. The script re-exports with AES-256-CBC encryption.
5. **Builds data packages** — per-user `.zip` files for both ATAK and iTAK,
   containing the client cert, CA truststore, and connection preferences
6. **Generates enrollment PDF** — printable slips with ATAK QR codes and
   iTAK data package import instructions

### Output

All artifacts are written to `~/enrollment-output/` on the server:

```
enrollment-output/
├── enrollment-slips.pdf        # Print and cut — one slip per user
├── passwords.csv               # Username;password pairs
└── datapackages/
    ├── anna-atak.zip           # ATAK data package
    ├── anna-itak.zip           # iTAK data package (iOS-compatible P12)
    ├── erik-atak.zip
    ├── erik-itak.zip
    └── ...
```

## CSV format

Semicolon-separated, first line is skipped as header. Every row must have 5
columns (use empty fields with semicolons if not needed).

```
Name;Username;Groups;IN Groups;OUT Groups
```

| Field | Description |
|-------|-------------|
| Name | Real name (used on PDF slip only) |
| Username | TAK Server username |
| Groups | Primary groups (comma-separated) — user can see and be seen |
| IN Groups | Groups that can see this user, but user cannot see them |
| OUT Groups | Groups this user can see, but they cannot see the user |

### Example

```csv
Name;Username;Groups;IN Groups;OUT Groups
Anna Svensson;anna;blue_team;;
Erik Nilsson;erik;red_team;judges;
Maria Lindberg;maria;blue_team,medics;judges;incidents
Judge, James;jamesj;judges;;
```

## Initial deployment

To provision users during the first deployment, create `users.csv` before
running `deploy.sh`:

```bash
cp users.csv.example users.csv
# Edit users.csv with your users
./deploy.sh
```

The deploy script uploads `users.csv`, and `setup-enrollment.sh` will run the
full provisioning flow after TAK Server is up. Artifacts are automatically
downloaded to `enrollment-output/` in your local directory.

## Adding users later

Upload a CSV and run provisioning:

```bash
scp users.csv tak@tak.example.com:/tmp/ && \
  ssh tak@tak.example.com 'sudo /opt/tak-enrollment/provision.sh /tmp/users.csv'
```

Then download all artifacts:

```bash
scp -r tak@tak.example.com:~/enrollment-output/ .
```

Replace `tak.example.com` with your TAK Server domain.

## Deleting users

```bash
scp users.csv tak@tak.example.com:/tmp/ && \
  ssh tak@tak.example.com 'sudo /opt/tak-enrollment/provision.sh /tmp/users.csv --delete'
```

## Distributing to users

### ATAK (Android)

1. Print enrollment PDF and cut into slips
2. User opens ATAK → Settings → Network Preferences → Quick Connect
3. Scans the QR code on their slip
4. Enters password when prompted

Or send the `-atak.zip` data package file and import it directly in ATAK.

### iTAK (iOS)

1. AirDrop or email the `-itak.zip` data package to the user's iPhone/iPad
2. Open the file — iOS offers to open it in iTAK
3. In iTAK: confirm the import, then tap on the server to connect
4. Enter password when prompted

## Important notes

- **Existing users are skipped** — if a username already exists on the server,
  the tool will not modify it or change its password.
- **Passwords are randomly generated** — each user gets a unique 20-character
  password. Passwords are in both the PDF slips and `passwords.csv`.
- **Groups are auto-created** — TAK Server creates groups automatically if they
  don't exist.
- **All clients use port 8089** (mTLS) — both ATAK and iTAK connect with
  client certificates on the same port.
- **iOS P12 compatibility** — iTAK data packages use AES-256-CBC encrypted
  P12 files (not the legacy RC2-40-CBC that TAK Server generates by default).

## Files on the server

| Path | Description |
|------|-------------|
| `/opt/tak-enrollment/provision.sh` | Main provisioning script |
| `/opt/tak-enrollment/enroll.sh` | Legacy wrapper (calls provision.sh) |
| `/opt/tak-enrollment/generate-enrollment-pdf.py` | PDF generator |
| `/opt/tak-enrollment/admin.pem` | Admin certificate (API auth) |
| `/opt/tak-enrollment/admin-key.pem` | Admin private key |
| `/opt/tak-enrollment/TAK-mass-enrollment/` | Cloned enrollment repo |
| `~/enrollment-output/` | Generated artifacts (PDF, data packages) |

## Re-running setup

```bash
ssh tak@tak.example.com 'sudo bash /opt/scripts/setup-enrollment.sh'
```
