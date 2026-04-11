#!/usr/bin/env python3
"""Generate TAK enrollment slips as PDF with both ATAK and iTAK QR codes.

Each user gets one page with:
  - Name, username, password (if available)
  - ATAK QR code (left) — auto-enrolls with embedded password
  - iTAK QR code (right) — server connection info
  - Setup instructions for both apps
  - iTAK data package import instructions

Usage:
  python generate-enrollment-pdf.py <users.csv> [passwords.csv]

If passwords.csv is not specified, looks for it next to users.csv.
TAK_DOMAIN is read from config.env, environment, or defaults to config.

ATAK QR: tak://com.atakmap.app/enroll?host=<domain>&username=<user>&token=<password>
iTAK QR: Name,Address,Port,Protocol (port 8089 mTLS)

Requires: fpdf2, qrcode, Pillow
"""

import csv
import io
import os
import sys
import tempfile
from urllib.parse import quote

import qrcode
from fpdf import FPDF


def load_config_env():
    """Load TAK_DOMAIN from config.env if present."""
    for path in ["config.env", "/opt/scripts/config.env"]:
        if os.path.isfile(path):
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("TAK_DOMAIN="):
                        return line.split("=", 1)[1].strip('"').strip("'")
    return None


# Config
TAK_DOMAIN = os.environ.get("TAK_DOMAIN") or load_config_env() or "tak.example.com"
TAK_PORT = "8089"
TAK_PROTOCOL = "ssl"
OUTPUT_FILE = "enrollment-slips.pdf"


def write_qr_temp(data: str) -> str:
    """Generate QR code PNG locally, write to temp file, return path."""
    img = qrcode.make(data, box_size=10, border=2)
    tmp = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
    img.save(tmp, format="PNG")
    tmp.close()
    return tmp.name


def main():
    users_csv = sys.argv[1] if len(sys.argv) > 1 else "users.csv"
    passwords_csv = sys.argv[2] if len(sys.argv) > 2 else None

    # Auto-detect passwords.csv next to users.csv
    if not passwords_csv:
        candidate = os.path.join(os.path.dirname(users_csv) or ".", "passwords.csv")
        if os.path.isfile(candidate):
            passwords_csv = candidate

    # Load passwords keyed by username
    passwords = {}
    if passwords_csv and os.path.isfile(passwords_csv):
        with open(passwords_csv, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f, delimiter=";")
            for row in reader:
                passwords[row["Username"]] = row["Password"]
        print(f"Loaded passwords for {len(passwords)} users from {passwords_csv}")

    # Parse users
    users = []
    with open(users_csv, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter=";")
        for row in reader:
            users.append({
                "name": row["Name"],
                "username": row["Username"],
            })

    if not users:
        print("No users found in CSV")
        sys.exit(1)

    print(f"Generating enrollment slips for {len(users)} users...")

    pdf = FPDF(orientation="P", unit="mm", format="A4")
    pdf.set_auto_page_break(auto=False)

    # Page dimensions
    page_w = 210
    margin = 15
    qr_mm = 60

    for user in users:
        username = user["username"]
        name = user["name"]
        pw = passwords.get(username)

        # iTAK QR data: Name,Address,Port,Protocol (port 8089 mTLS)
        itak_server_name = f"{name} - {TAK_DOMAIN}"
        itak_qr_data = f"{itak_server_name},{TAK_DOMAIN},{TAK_PORT},{TAK_PROTOCOL}"

        # ATAK QR data: tak:// enrollment URL (requires password)
        atak_qr_data = None
        if pw:
            atak_qr_data = (
                f"tak://com.atakmap.app/enroll?"
                f"host={TAK_DOMAIN}&username={username}&token={quote(pw)}"
            )

        print(f"  {username}: iTAK{'+ ATAK' if atak_qr_data else ' only (no password)'}")

        # Generate QR images
        itak_tmp = write_qr_temp(itak_qr_data)
        atak_tmp = write_qr_temp(atak_qr_data) if atak_qr_data else None

        pdf.add_page()

        # --- Title ---
        pdf.set_font("Helvetica", "B", 22)
        pdf.cell(0, 12, "TAK Server Enrollment", ln=True, align="C")
        pdf.ln(3)

        # --- User info ---
        pdf.set_font("Helvetica", "", 14)
        pdf.cell(0, 8, f"Name: {name}", ln=True, align="C")
        pdf.cell(0, 8, f"Username: {username}", ln=True, align="C")
        if pw:
            pdf.cell(0, 8, f"Password: {pw}", ln=True, align="C")
        pdf.ln(4)

        # --- QR codes side by side ---
        qr_y = pdf.get_y()

        if atak_tmp:
            # Two QR codes: ATAK left, iTAK right
            gap = 20
            total_w = qr_mm * 2 + gap
            left_x = (page_w - total_w) / 2
            right_x = left_x + qr_mm + gap

            # Labels above QR
            pdf.set_font("Helvetica", "B", 13)
            pdf.set_xy(left_x, qr_y)
            pdf.cell(qr_mm, 8, "ATAK", align="C")
            pdf.set_xy(right_x, qr_y)
            pdf.cell(qr_mm, 8, "iTAK", align="C")

            qr_y += 9
            pdf.image(atak_tmp, x=left_x, y=qr_y, w=qr_mm, h=qr_mm)
            pdf.image(itak_tmp, x=right_x, y=qr_y, w=qr_mm, h=qr_mm)
        else:
            # Only iTAK QR, centered
            left_x = (page_w - qr_mm) / 2

            pdf.set_font("Helvetica", "B", 13)
            pdf.cell(0, 8, "iTAK", ln=True, align="C")
            qr_y = pdf.get_y()
            pdf.image(itak_tmp, x=left_x, y=qr_y, w=qr_mm, h=qr_mm)

        pdf.set_y(qr_y + qr_mm + 5)

        # --- Scissors line ---
        pdf.set_draw_color(180, 180, 180)
        pdf.dashed_line(margin, pdf.get_y(), page_w - margin, pdf.get_y(), 2, 2)
        pdf.ln(5)

        # --- Instructions ---
        pdf.set_font("Helvetica", "B", 11)
        col_w = (page_w - 2 * margin) / 2

        if atak_tmp:
            # Two-column instructions
            inst_y = pdf.get_y()

            pdf.set_xy(margin, inst_y)
            pdf.cell(col_w, 7, "ATAK", align="C", ln=True)
            pdf.set_x(margin)
            pdf.set_font("Helvetica", "", 9)
            atak_steps = [
                "1. Open ATAK",
                "2. Menu > Settings > Network",
                "3. TAK Servers > Add",
                "4. Tap QR Code and scan the left code",
                "5. Connection auto-configures",
            ]
            for line in atak_steps:
                pdf.set_x(margin)
                pdf.cell(col_w, 5, line, ln=True)

            pdf.set_xy(margin + col_w, inst_y)
            pdf.set_font("Helvetica", "B", 11)
            pdf.cell(col_w, 7, "iTAK", align="C", ln=True)
            pdf.set_font("Helvetica", "", 9)
            itak_steps = [
                "1. Import data package (.zip) via",
                "   AirDrop/email/Files app",
                "2. Open with iTAK",
                "3. Certificate + server auto-configure",
                "4. Or: scan QR + import cert manually",
            ]
            for line in itak_steps:
                pdf.set_x(margin + col_w)
                pdf.cell(col_w, 5, line, ln=True)
        else:
            pdf.cell(0, 7, "iTAK", align="C", ln=True)
            pdf.set_font("Helvetica", "", 9)
            for line in [
                "1. Import data package (.zip) via AirDrop/email",
                "2. Open with iTAK",
                "3. Certificate + server auto-configure",
                "4. Or: scan QR + import cert manually",
            ]:
                pdf.cell(0, 5, line, ln=True, align="L")

        # --- Footer ---
        pdf.set_y(-20)
        pdf.set_font("Helvetica", "I", 8)
        pdf.set_text_color(120, 120, 120)
        pdf.cell(0, 5, f"Server: {TAK_DOMAIN}  |  mTLS: {TAK_PORT}  |  Enrollment: 8446", ln=True, align="C")
        pdf.set_text_color(0, 0, 0)

        # Cleanup temp files
        os.unlink(itak_tmp)
        if atak_tmp:
            os.unlink(atak_tmp)

    pdf.output(OUTPUT_FILE)
    print(f"\nSaved: {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
