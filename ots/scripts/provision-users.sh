#!/usr/bin/env bash
# =============================================================================
# provision-users.sh — Create OTS users from users.csv
# =============================================================================
# Reads users.csv (semicolon-delimited), creates each user in OpenTAK Server
# via the REST API, assigns groups, and outputs login instructions.
#
# Usage:
#   ./provision-users.sh                              # uses users.csv in same dir
#   ./provision-users.sh /path/to/users.csv           # custom CSV path
#   OTS_DOMAIN=tak.example.com ./provision-users.sh   # override domain
#
# Environment variables:
#   OTS_DOMAIN   — domain for login instructions (default: read from config.env)
#   OTS_HOST     — API host (default: localhost:8081 when run on server)
#   OTS_ADMIN    — admin username (default: administrator)
#   OTS_PASSWORD — admin password (default: password)
#
# CSV format (semicolon-delimited):
#   Name;Username;Groups;IN Groups;OUT Groups
#   Anna Svensson;anna;blue_team;;
#   Maria Lindberg;maria;blue_team,medics;judges;incidents
#
# Output:
#   - Creates users with random passwords
#   - Assigns groups (both directions for "Groups", directional for IN/OUT)
#   - Writes passwords.csv (username;password)
#   - Prints login instructions for the OTS admin GUI
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Config ---
CSV_FILE="${1:-${REPO_DIR}/users.csv}"
OTS_HOST="${OTS_HOST:-localhost:8081}"
OTS_ADMIN="${OTS_ADMIN:-administrator}"
OTS_PASSWORD="${OTS_PASSWORD:-password}"
OTS_ADDRESS="http://${OTS_HOST}"

# Try to read OTS_DOMAIN from config.env if not set
if [[ -z "${OTS_DOMAIN:-}" ]]; then
  if [[ -f "${REPO_DIR}/config.env" ]]; then
    OTS_DOMAIN=$(grep '^OTS_DOMAIN=' "${REPO_DIR}/config.env" | cut -d'"' -f2)
  fi
fi
OTS_DOMAIN="${OTS_DOMAIN:-tak.example.com}"

# --- Validate ---
if [[ ! -f "$CSV_FILE" ]]; then
  echo "ERROR: CSV file not found: $CSV_FILE" >&2
  echo "Usage: $0 [users.csv]" >&2
  exit 1
fi

OUTPUT_DIR="${REPO_DIR}/enrollment-output"
mkdir -p "$OUTPUT_DIR"
PASSWORD_FILE="${OUTPUT_DIR}/passwords.csv"

# --- Generate password ---
generate_password() {
  openssl rand -base64 16 | tr -d '/+=' | head -c 16
}

# --- Python provisioning script ---
provision() {
  python3 << 'PYEOF' "$CSV_FILE" "$OTS_ADDRESS" "$OTS_ADMIN" "$OTS_PASSWORD" "$PASSWORD_FILE"
import csv
import json
import sys
import os
import subprocess

csv_file = sys.argv[1]
address = sys.argv[2]
admin_user = sys.argv[3]
admin_pass = sys.argv[4]
password_file = sys.argv[5]

try:
    import requests
except ImportError:
    print("Installing requests...", file=sys.stderr)
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "requests"])
    import requests

def generate_password():
    """Generate a 16-char alphanumeric password (no @ or : for OTS compat)."""
    import base64
    raw = base64.b64encode(os.urandom(16)).decode()
    return ''.join(c for c in raw if c.isalnum())[:16]

# --- Authenticate ---
print("Authenticating to OTS API...", file=sys.stderr)
s = requests.session()
r = s.get(f"{address}/api/login", json={}, verify=False)
if r.status_code != 200:
    print(f"ERROR: Cannot reach OTS API at {address}: {r.status_code}", file=sys.stderr)
    sys.exit(1)

csrf_token = r.json()["response"]["csrf_token"]
s.headers["X-XSRF-TOKEN"] = csrf_token
s.headers["Referer"] = address

r = s.post(f"{address}/api/login",
    json={"username": admin_user, "password": admin_pass}, verify=False)
if r.status_code != 200:
    print(f"ERROR: Login failed (status {r.status_code}). Check admin credentials.", file=sys.stderr)
    sys.exit(1)
print("Authenticated.", file=sys.stderr)

# --- Read CSV ---
users = []
with open(csv_file, newline='', encoding='utf-8-sig') as f:
    reader = csv.DictReader(f, delimiter=';')
    for row in reader:
        users.append({
            'name': row['Name'].strip(),
            'username': row['Username'].strip(),
            'groups': [g.strip() for g in row.get('Groups', '').split(',') if g.strip()],
            'in_groups': [g.strip() for g in row.get('IN Groups', '').split(',') if g.strip()],
            'out_groups': [g.strip() for g in row.get('OUT Groups', '').split(',') if g.strip()],
        })

if not users:
    print("ERROR: No users found in CSV.", file=sys.stderr)
    sys.exit(1)

print(f"Found {len(users)} users in CSV.", file=sys.stderr)

# --- Ensure groups exist ---
all_groups = set()
for u in users:
    all_groups.update(u['groups'])
    all_groups.update(u['in_groups'])
    all_groups.update(u['out_groups'])

if all_groups:
    r = s.get(f"{address}/api/groups/all")
    existing_groups = set()
    if r.status_code == 200:
        for g in r.json().get('results', []):
            existing_groups.add(g.get('name', ''))

    for group in sorted(all_groups):
        if group not in existing_groups:
            r = s.post(f"{address}/api/groups", json={"name": group})
            if r.status_code in (200, 201):
                print(f"  Created group: {group}", file=sys.stderr)
            else:
                print(f"  Warning: Could not create group '{group}': {r.status_code} {r.text[:100]}", file=sys.stderr)

# --- Create users ---
results = []
for u in users:
    username = u['username']
    password = generate_password()

    r = s.post(f"{address}/api/user/add",
        json={"username": username, "password": password})

    if r.status_code in (200, 201):
        status = "created"
    elif r.status_code == 400:
        # User might already exist
        status = "exists"
        print(f"  {username}: already exists (skipping password)", file=sys.stderr)
    else:
        status = f"error:{r.status_code}"
        print(f"  {username}: ERROR {r.status_code} - {r.text[:200]}", file=sys.stderr)
        results.append({'username': username, 'name': u['name'], 'password': '???', 'status': status})
        continue

    # --- Assign groups ---
    # "Groups" column = both IN and OUT
    for direction in ["IN", "OUT"]:
        groups_to_add = list(u['groups'])
        if direction == "IN":
            groups_to_add += u['in_groups']
        else:
            groups_to_add += u['out_groups']

        if groups_to_add:
            r2 = s.put(f"{address}/api/users/groups",
                json={"username": username, "groups": groups_to_add, "direction": direction})
            if r2.status_code not in (200, 201):
                print(f"  {username}: Warning — group assign ({direction}) failed: {r2.status_code}", file=sys.stderr)

    if status == "created":
        results.append({'username': username, 'name': u['name'], 'password': password, 'status': status})
        print(f"  {username}: created", file=sys.stderr)
    else:
        results.append({'username': username, 'name': u['name'], 'password': '(unchanged)', 'status': status})

# --- Write passwords.csv ---
with open(password_file, 'w', newline='') as f:
    writer = csv.writer(f, delimiter=';')
    writer.writerow(['Username', 'Password', 'Status'])
    for r in results:
        writer.writerow([r['username'], r['password'], r['status']])

# --- Output JSON for bash to parse ---
print(json.dumps(results))
PYEOF
}

echo "=== OTS User Provisioning ==="
echo "CSV:    $CSV_FILE"
echo "API:    $OTS_ADDRESS"
echo "Domain: $OTS_DOMAIN"
echo ""

RESULT=$(provision)
RC=$?

if [[ $RC -ne 0 ]]; then
  echo "ERROR: Provisioning failed." >&2
  exit 1
fi

echo ""
echo "Passwords saved to: $PASSWORD_FILE"
echo ""

# --- Print login instructions ---
CREATED=$(echo "$RESULT" | python3 -c "
import json, sys
users = json.load(sys.stdin)
created = [u for u in users if u['status'] == 'created']
print(len(created))
")

TOTAL=$(echo "$RESULT" | python3 -c "
import json, sys
users = json.load(sys.stdin)
print(len(users))
")

echo "============================================================"
echo "  OTS Login Instructions"
echo "============================================================"
echo ""
echo "  Admin GUI:  https://${OTS_DOMAIN}/"
echo ""
echo "------------------------------------------------------------"

echo "$RESULT" | python3 -c "
import json, sys
users = json.load(sys.stdin)
for u in users:
    print()
    print(f'  Name:     {u[\"name\"]}')
    print(f'  Username: {u[\"username\"]}')
    if u['status'] == 'created':
        print(f'  Password: {u[\"password\"]}')
    else:
        print(f'  Password: (not changed — user already existed)')
    print(f'  Status:   {u[\"status\"]}')
    print('  ---')
"

echo ""
echo "------------------------------------------------------------"
echo "  ${CREATED} created, ${TOTAL} total"
echo "============================================================"
