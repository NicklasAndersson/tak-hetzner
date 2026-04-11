#cloud-config
# =============================================================================
# Official TAK Server (GoC) — Hetzner VPS
# =============================================================================
# Version:    1.0.0
# Date:       2026-03-07
#
# Phase 1: Cloud-init sets up the base system (hardening, Docker, scripts).
# Phase 2: User SCPs the TAK Server Docker zip and runs setup-all.sh.
#
# References:
#   - https://tak.gov/products/tak-server
#   - https://mytecknet.com/lets-build-a-tak-server/
#   - https://github.com/Cloud-RF/tak-server
#
# Configure variables in config.env, then run ./build.sh
# =============================================================================

# --- System settings ---
hostname: {{TAK_HOSTNAME}}
timezone: {{TAK_TIMEZONE}}
locale: {{TAK_LOCALE}}

# --- Create tak user with sudo privileges ---
users:
  - name: tak
    groups: [sudo, docker]
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - {{SSH_PUBLIC_KEY}}

# --- Package management ---
package_update: true
package_upgrade: true
package_reboot_if_required: true

packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - git
  - jq
  - htop
  - tmux
  - unzip
  - fail2ban
  - ufw
  - ipset
  - unattended-upgrades
  - update-notifier-common
  - dnsutils
  - certbot
  - openjdk-17-jdk

# --- Write configuration files ---
write_files:
  # --- ipsum blocklist (block port scanning bots) ---
  - path: /opt/ipsum.sh
    content: |
      #!/bin/bash
      ipset -q create ipsum hash:ip
      ipset -q create ipsum_tmp hash:ip
      ipset -q flush ipsum_tmp
      curl -fsSL --compressed https://raw.githubusercontent.com/stamparm/ipsum/master/levels/3.txt \
        | grep -v "^#" | sed '/^$/d' \
        | sed 's/^/add ipsum_tmp /' | ipset restore -!
      ipset swap ipsum_tmp ipsum
      ipset destroy ipsum_tmp
      iptables -C INPUT -m set --match-set ipsum src -j DROP 2>/dev/null \
        || iptables -I INPUT -m set --match-set ipsum src -j DROP
    permissions: '0755'

  # --- Fail2Ban ---
  - path: /etc/fail2ban/jail.local
    content: |
      [DEFAULT]
      bantime  = 3600
      findtime = 600
      maxretry = 5
      backend  = systemd

      [sshd]
      enabled  = true
      port     = 22
      filter   = sshd
      logpath  = /var/log/auth.log
      maxretry = 3
    permissions: '0644'

  # --- SSH hardening ---
  - path: /etc/ssh/sshd_config.d/99-hardening.conf
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      PubkeyAuthentication yes
      X11Forwarding no
      MaxAuthTries 3
      AllowUsers tak
    permissions: '0644'

  # --- Automatic security updates ---
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";
    permissions: '0644'

  - path: /etc/apt/apt.conf.d/50unattended-upgrades
    content: |
      Unattended-Upgrade::Allowed-Origins {
          "${distro_id}:${distro_codename}-security";
          "${distro_id}ESMApps:${distro_codename}-apps-security";
          "${distro_id}ESM:${distro_codename}-infra-security";
      };
      Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
      Unattended-Upgrade::Remove-Unused-Dependencies "true";
      Unattended-Upgrade::Automatic-Reboot "false";
    permissions: '0644'

  # --- Configuration variables ---
  - path: /opt/scripts/config.env
    permissions: '0644'
    content: |
      # TAK Server configuration
      TAK_DOMAIN="{{TAK_DOMAIN}}"
      CERTBOT_EMAIL="{{CERTBOT_EMAIL}}"
      TAK_CA_PASS="{{TAK_CA_PASS}}"
      TAK_ADMIN_PASS="{{TAK_ADMIN_PASS}}"
      # Certificate details
      TAK_STATE="{{TAK_STATE}}"
      TAK_CITY="{{TAK_CITY}}"
      TAK_ORGANIZATION="{{TAK_ORGANIZATION}}"
      TAK_ORGANIZATIONAL_UNIT="{{TAK_ORGANIZATIONAL_UNIT}}"
      # CloudTAK configuration
      CLOUDTAK_DOMAIN="{{CLOUDTAK_DOMAIN}}"
      TILES_DOMAIN="{{TILES_DOMAIN}}"

  # --- TAK Server setup script ---
  - path: /opt/scripts/setup-tak.sh
    permissions: '0755'
    encoding: gz+b64
    content: |
      PLACEHOLDER

  # --- Let's Encrypt setup script ---
  - path: /opt/scripts/setup-letsencrypt.sh
    permissions: '0755'
    encoding: gz+b64
    content: |
      PLACEHOLDER

  # --- Setup-all orchestration ---
  - path: /opt/scripts/setup-all.sh
    permissions: '0755'
    encoding: gz+b64
    content: |
      PLACEHOLDER

  # --- CloudTAK setup script ---
  - path: /opt/scripts/setup-cloudtak.sh
    permissions: '0755'
    encoding: gz+b64
    content: |
      PLACEHOLDER

  # --- Enrollment setup script ---
  - path: /opt/scripts/setup-enrollment.sh
    permissions: '0755'
    encoding: gz+b64
    content: |
      PLACEHOLDER

  # --- Swap configuration ---
  - path: /etc/sysctl.d/99-swap.conf
    content: |
      vm.swappiness=10
    permissions: '0644'

# --- Commands at first boot ---
runcmd:
  # ── Docker CE ──
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo ${UBUNTU_CODENAME:-$VERSION_CODENAME}) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  - apt-get update -qq
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker tak

  # ── Swap (2 GB) ──
  - fallocate -l 2G /swapfile
  - chmod 600 /swapfile
  - mkswap /swapfile
  - swapon /swapfile
  - echo '/swapfile none swap sw 0 0' >> /etc/fstab
  - sysctl -p /etc/sysctl.d/99-swap.conf

  # ── UFW firewall ──
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 22/tcp comment 'SSH'
  - ufw allow 80/tcp comment 'HTTP (certbot)'
  - ufw allow 443/tcp comment 'HTTPS'
  - ufw allow 8089/tcp comment 'TAK Server SSL CoT'
  - ufw allow 8443/tcp comment 'TAK Server HTTPS API'
  - ufw allow 8446/tcp comment 'TAK Server Certificate Enrollment'
  - ufw allow 9000/tcp comment 'TAK Server Federation (v1)'
  - ufw allow 9001/tcp comment 'TAK Server Federation (v2)'
  - ufw --force enable

  # ── Fail2ban ──
  - systemctl enable fail2ban
  - systemctl start fail2ban

  # ── ipsum blocklist (block known malicious IPs) ──
  - bash /opt/ipsum.sh
  - echo '0 0 * * * /opt/ipsum.sh' | crontab -

  # ── Prepare installer directory ──
  - mkdir -p /opt/tak-installer
  - chown tak:tak /opt/tak-installer

  # ── Caddy web server (reverse proxy for CloudTAK) ──
  - curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  - echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" | tee /etc/apt/sources.list.d/caddy-stable.list
  - apt-get update -qq
  - apt-get install -y caddy
  - systemctl disable caddy
  - systemctl stop caddy

final_message: |
  ===========================================
   Base system ready! Time: $UPTIME seconds
   SSH: ssh tak@{{TAK_DOMAIN}}
   Next: deploy.sh will upload TAK Server zip
         and run setup-all.sh automatically.
  ===========================================
