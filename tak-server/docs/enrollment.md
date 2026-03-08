# Mass User Enrollment

Bulk-create TAK Server users from a CSV file and generate ATAK Quick Connect
QR codes. Based on [TAK-mass-enrollment](https://github.com/sgofferj/TAK-mass-enrollment).

## How it works

The enrollment tool connects to the TAK Server API (port 8443) using the admin
certificate and creates users with randomly generated passwords. It produces a
PDF (`enrollment-slips.pdf`) with printable slips containing each user's name,
groups, and a QR code that ATAK can scan to auto-configure the server connection.

The tool is installed automatically during deployment at `/opt/tak-enrollment/`.

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

- Anna is in `blue_team`
- Erik is in `red_team` and visible to `judges`
- Maria is in `blue_team` and `medics`, visible to `judges`, can see `incidents`
- James is in `judges`

## Initial deployment

To enroll users during the first deployment, create a `users.csv` file in the
`tak-server/` directory before running `deploy.sh`:

```bash
cp users.csv.example users.csv
# Edit users.csv with your users
./deploy.sh
```

The deploy script automatically uploads `users.csv` to the server. The
`setup-enrollment.sh` script detects it and runs enrollment after TAK Server
is up.

## Adding users later (SSH one-liner)

Upload a CSV and run enrollment in one command:

```bash
scp users.csv tak@tak.example.com:/tmp/ && \
  ssh tak@tak.example.com 'sudo /opt/tak-enrollment/enroll.sh /tmp/users.csv'
```

Then download the enrollment PDF:

```bash
scp tak@tak.example.com:/opt/tak-enrollment/TAK-mass-enrollment/enrollment-slips.pdf .
```

Replace `tak.example.com` with your TAK Server domain.

## Deleting users

To delete all users listed in a CSV:

```bash
scp users.csv tak@tak.example.com:/tmp/ && \
  ssh tak@tak.example.com 'sudo /opt/tak-enrollment/enroll.sh /tmp/users.csv --delete'
```

## Important notes

- **Existing users are skipped** — if a username already exists on the server,
  the tool will not modify it. This is a safety feature to prevent overwriting
  admin accounts or changing passwords.
- **Passwords are randomly generated** — each user gets a unique 20-character
  password. The passwords are printed in the enrollment PDF slips.
- **Groups are auto-created** — TAK Server creates groups automatically if they
  don't exist.
- **ATAK only** — the QR codes work with ATAK Quick Connect. For CloudTAK users,
  additional steps are needed (client cert + profile injection). See
  [ports.md](ports.md) for CloudTAK user setup.

## Files on the server

| Path | Description |
|------|-------------|
| `/opt/tak-enrollment/enroll.sh` | Wrapper script (run this) |
| `/opt/tak-enrollment/admin.pem` | Admin certificate (for API auth) |
| `/opt/tak-enrollment/admin-key.pem` | Admin private key (unencrypted) |
| `/opt/tak-enrollment/users.csv` | Initial CSV (if uploaded during deploy) |
| `/opt/tak-enrollment/TAK-mass-enrollment/` | Cloned repository |
| `/opt/tak-enrollment/TAK-mass-enrollment/enrollment-slips.pdf` | Generated PDF |

## Re-running setup

If you need to reinstall or update the enrollment tool:

```bash
ssh tak@tak.example.com 'sudo bash /opt/scripts/setup-enrollment.sh'
```
