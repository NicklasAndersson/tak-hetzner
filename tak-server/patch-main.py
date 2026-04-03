#!/usr/bin/env python3
"""Patch main.py on TAK server to save passwords to passwords.csv"""

with open("/opt/tak-enrollment/TAK-mass-enrollment/main.py") as f:
    content = f.read()

# 1. Add csv import at top
content = content.replace(
    "import qrcode\n",
    "import qrcode\nimport csv as csvmod\n"
)

# 2. Add password file setup after data = func.readFile(csvfile)
content = content.replace(
    '    data = func.readFile(csvfile)\n\n    for chunks',
    '    data = func.readFile(csvfile)\n\n'
    '    # Save passwords to CSV file\n'
    '    pw_file = open("passwords.csv", "w", newline="")\n'
    '    pw_writer = csvmod.writer(pw_file, delimiter=";")\n'
    '    pw_writer.writerow(["Name", "Username", "Password"])\n\n'
    '    for chunks',
    1
)

# 3. After successful user creation, write password to file
content = content.replace(
    '                if result.status_code == 200:\n'
    '                    print(f"User \'{user}\' created")\n'
    '                else:',
    '                if result.status_code == 200:\n'
    '                    print(f"User \'{user}\' created")\n'
    '                    pw_writer.writerow([name, user, password])\n'
    '                else:',
    1
)

# 4. Close password file before pdf.save
content = content.replace(
    '    pdf.save("enrollment-slips.pdf")',
    '    pw_file.close()\n    pdf.save("enrollment-slips.pdf")',
    1
)

with open("/opt/tak-enrollment/TAK-mass-enrollment/main.py", "w") as f:
    f.write(content)

print("main.py patched - passwords will be saved to passwords.csv")
