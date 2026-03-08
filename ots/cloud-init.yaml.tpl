#cloud-config
# =============================================================================
# TAK Server Baseline — Hetzner VPS
# =============================================================================
# Version:    3.0.0
# Date:       2026-03-05
#
# Installs baseline dependencies, hardens the server, and automatically runs:
#   - OpenTAK Server
#   - Let's Encrypt
#   - CloudTAK
#   - ADS-B
#
# Configure domains and ADS-B position in the config.env block below.
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
  - python3
  - python3-pip
  - python3-venv

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
      # Domains
      OTS_DOMAIN="{{OTS_DOMAIN}}"
      CLOUDTAK_DOMAIN="{{CLOUDTAK_DOMAIN}}"
      TILES_DOMAIN="{{TILES_DOMAIN}}"
      # ADS-B position
      ADSB_LAT="{{ADSB_LAT}}"
      ADSB_LON="{{ADSB_LON}}"
      ADSB_RADIUS="{{ADSB_RADIUS}}"

  # --- Let's Encrypt setup script ---
  - path: /opt/scripts/setup-letsencrypt.sh
    permissions: '0755'
    encoding: gz+b64
    content: |
      H4sICJZEq2kAA3NldHVwLWxldHNlbmNyeXB0LnNoAL1aXXLbyBF+5ynasGSStgBK1sbrUKtNZIte
      qSSLLlHelEt2sSBiSGIJAjAwlKXIqtqHTQ6Q2krlIY/2FXwB3sQnSXfPABiAlLw/SVQui8T09PTv
      N90N3b3TOvPD1pmbjmt3Yfu/+YP8UiFnsR0ImYpwkFzG0knH8PnHn+FQyHoKHfUQhvNPCXRjEZ7s
      HEBPJOci+R8IczD/EARuG8ZSxmm71fKiQepEeKp0Jykf6vhRi4TtZ9KO5TSo3cW937sepIPEj6WQ
      MEJx2/gQYMOB/TCVbhCIxE1gIBJ5FkloRFPwkDB1J6GbNpn0oQM9GcUxkoUjP7wA6QfBkETyR5Ip
      Nh3Ym3+YSqQomccmtv7Qn7gSzn0X8LzQc4MoFDAY09HhSDCDrxx4GceeK1kYPsUeROHQH2kLn/Sg
      oZkNkApEmERBMEULwAPYOzl50YOvvtrEz4/xlxIbf7pPem144iZ4chr0jf2tyvf+RFzC2aVMYSad
      bDfTBD6eYZJCNBjzElrdH15qCjgT4/nHIEihMT057DVzJrtCSheC+Sf0E+z1Tnr2BPUK/IkUIcfT
      Mz8Rw+gCzoJoMGH1UxEM7dQfhcJjv2Ss4vlHQPuhNnGUkK3RV8QR5h8ScCfSP5dMQ6tkDSXDH8h7
      LtMr7/kjEfLKI1yZf5Boc5jFMbgzGU1d6acTtnl4KYJUKLddplJMPfT7lMIbN++E5/MPoRf64UiF
      UzrzIqBUXJo4vOcgcc8VsV3JGEiE54bg5/EoNdnuUQ927DhKUTExQQ1IPRXwYQr7LzTZC1L48TrM
      P8XIF3w4S9BOKOFIqfrfTUdUEGwxiyD2YzF0/aCGRxy6nueCCllHhOfAeRTC0A/DtPa0e/Rs/7t+
      5+j7basVxbKlEjJtFRusmj+E01Owh2CtFPQWvHmzBXKMeqCRo1kyEOX12tCv1Xa7z3f2j7atlauN
      tr1yhdnSV4/aNiKEMz6302jkpOL62qrR4ste55ioH/K6frjXfd5B8cbRVLQUDyLDRVTvGYbYCH1/
      3Nndrr9e39w8Xd/a3JjWa98ddzpHxaOH+OhV5/Cw+xf9bGNrcxOfHT3NaPBLLYhGjSbAFYjBOEJb
      okZXzOj69PO/f36zcnX09BpW7ltbcF175yYhEpdo1QnXp3fKpCJJFtiiwMT0XyaluPAlbNAO1Ozz
      zz/iPziIQkmIgsGontTQFyudl/u7YCNaraMb4N49wCPAOiBEStHBSRTJthH6K+toLD7c+jURZek9
      lauFE2nZBZPT70ZTzMI2rFwpb19bv+N09nNhBhdcKRl3y2is4rlzfILRd9w9PHzeOTrBqBFy0GLC
      VupLkdoidM8C4bUivJJMnC1w26oxbPdVLH+BBV98KCE65Y5OkbIIlumgPR8x1xMIKAjXK1cV0muG
      XcJM0s4AnT9ZBn9TuNuYm3S3ca4YF5FN2914mjDgscdzlzqOY2Ha9bqH33d2+/svtlcaHvrhQTom
      0LMK18MOvIexwNve3mhmYPJXpDA2l9CEtdnHGzjMMHasVEurIqhrgi+JTMBUOgw9mMpg0cPugRGH
      8Pnv/wBKvvxkBSM62Uq1R1566LxDye8gkE6nCOFgn+fL976FlifOW+EsCHIdCB3AykhU0bJmWD5h
      8wG4WIuMBKlANQbYb98aDzU52JfZYbjIimWMDVdiuuC1WCVYuMAULuca5yWUvoO1rkr8m4srll7d
      vgMZYPkUxYpK2V1tSHm7Zxo4r8fAKMD0mVm2q99fKttYgkxL+h2FwSW8Rv1t26jm1IMYKxmMKuHZ
      eXWXcs2q18MotCltEneAxUq2yx0lQtgySvV3McU7FSzXm/rhn4345lXPDPla7bDTp+zW6GEUHa0A
      D2jlpK0hRg0K5YdOLKYW7TvovPrytjjxz7E0VJsMdNDnloDhaW40qp8nbsypRPpSZugdKDS7riCG
      MbtAlokKX2JpzJAD4ezcpbpGsB/sBNknWOuUAuqupiX8Yap0/mlChRC6uIHbfUaZM5FEghipipJL
      OYxEdxo2uRJgk6400C8x2NMNqFeqZagvA+D3eGN5SNty7lfpW616sbylvl24yShV55ErbjmOi/Nf
      eSTvueVYEyAzlZHf++IJCrUIlwezMIN+BstqX4H+WLxvFBaw249yH2YeIrdnAmTBUaZCTdqgqVCo
      UnBgcf/EHUywTnDPyxe1DognO08PXr7o7+4fl27YM95k411CQj9YfbU6XfXs1b3V56u9plWbTjw/
      ATtGUxQMEAfiZU4waVqaqHx7VihYRy12isCHVxaZraApq3hm9Ia6+O9jrJKtq+VJWuQBLtk5HoeQ
      6kbH3E9Iy77E0AeKfux+zZ66Tx0l2syhfpLqPfY7tkgIJAl3yQm2cf7IBY8LMWIhpEMtHwxnCH6U
      az74aRRgWxWFazDldiSkCuFpEM08qukCalNSJcwUQ1WMUBo82eaGkLvNSYSgOpGm8GvIJ4lmRVeH
      UtuJeDsTqdTMshMUI5SJLuWhCDjsNC83dWrDKOHGhfn2Yxc97+OttGCKtoHFldXHX1x+ZCxvob0w
      oaLA4yOpESmfv7ravn9N13Yo3t1Acvfu/TaTZNKzzMuCsxSK+mgATH+FN2/BMmNi5SoT63qLdhNr
      Cx5+u1h68IQA/WX7yKF1E4/KQqYQLuTcNS/OihvY6Hoq30350sCWQ2hC4nPdVJwQawC1DEWN/ysS
      6ZGZRzfX5VkK5bq9r2Kcc9+ALOf+wnpxj229t5Y45WbWjNoZe8K6Re5MwifQ+g0HsC1zZeVSTC4M
      83XVMNxtQGPn8HBH54nKobY5Yyqg5sml/EXzJc7Kco/nA+KTq2Y/NK75VSMnRI4p1rvQfTb/5/H8
      p6Pd453djjF/um301M7nTiQVMqIClIdJXBOQUGrIhHy4G0hdrMg10K0hnH5cGFPxTjJNPspKaQpC
      D8aauVOLL+U4Cjfhm2/gxatO91nNn/K4KsFIfefLMRByNKxKX2WtgZVYTUCOwzZHOUa8JBtsw9BJ
      sOlpNGvLPZHbruoNHxb8S0Z7ruFdlVcEyHTJVHU16iratH900rnJdw0aA2E5mE0IXd1eaTcFfohV
      4namkJPGgS8b9ddhvVlLRDoLSMfTNzWGaSImoONNyhCpTPw4RrG2+anD39EatKYNojRkFzUqllhT
      d9py0ZsZUmZnIHM3kSn5qbFYEzZpOAl1AxvqmaxtjXHIDasadhs9Pm1jj9CgT02wIfvsBFqH5pt8
      GyuOvq5fKQbXt2BOnXeJ4BcKTsFQlp2A5f8negXQlPTK845L80xPHfOl/HhXyo+h8y7xpeBAcn6I
      /LChWDabNZV3ixBZnmQ0simyxjv17qOjo4nkX+MQzgffTRNSHztwgpWIu7QmzTpQ7vRV9WJLvGPv
      bRTF9o0TvBJDSlSsaO7A/G+oRSqpbcasHSbzjyGoGlcPAAblWva2udSyC2U5AzWVqtYYNKg1WnYM
      PN2z6x7CkNVTd4KWtDQgmrrhTASBOWYpqd49MO39RwcOqY5kfmcuog1jeThTxea5z6Ya+QGXq4cd
      hQZF00jEMsIy9Iy87ushPl4D9NaL4Yqmgdj8nGPLyp+z62PgElxmPAgvq1jpwJEWIzuXPvOLCqyL
      U/7Gr5zmHyZEbt4RxLS/cFFkNZ8/wloQcwJT9dRacsevwUKivFHpUaSSwWfhkrnholHQajorexGj
      xkBqRqqx0+ohIgykfYINXUoa2D0xmGFuXlokt2ZfPs9H1+tTCq+qE8SQu5hFCOF5AL37wNbxB1G6
      1moZDC3eM9br0GoaiKPuGgaQ5dfNTeCUg+SwdA2ZwGstkdpSwFvagkz1hi2rWZz6OyB4UegCjV3P
      69PUFK16o6fAmroXtjsS2482179+uL6+bmGJ9M69TLfqzVvj6d1CPGXATJavALMR7Jzv7HAlG2bJ
      xwI1XGhUUrkEvhvr2Su/8nBoOSqVJom0yavyMiM9GwXyq0BjZFvw9lNbj/ds++3MFzLb4/CeHOJL
      81N694jtKzY4bqB5q1zi15r5zLU4Rb0cKLNeArzV9S8dysehnl5lfrux4cCxorTHUTTB7sCYfk6S
      +Qd6jUm4aM5k07xJ2Ot2D/ovjjtLJo6JybYVJ9g74Gab+SD6Wnpvt7dsylnZHKWyxYob2/NZzhc2
      X+HRa8ThOhuOZW9CtOylaRgmMHxbWkS0rvM3jN967a7xxxlLB9gZKfEaTyMPHlyY7DJfaaMDCsdy
      6sEqmd8YmjeVu5aIjWa7RW5e/WWCFwlzm+TEcEF0tGlVduN9fLMSageBm1Qrpd/8Vo9KKMherpZb
      zwkD1Syh6u8O11ZW5bz8/SL9LLxjhKc8vdSLxeRarx7w1LJYVZNLvaiGf221WJr7VSSY/0R/7+AJ
      vFMRftr5c3rrv6ypLy3fXtA2Fw7bMfCgXYYOHp7DxsM2TQ2nU7G4mfvroX9hyqj+LoGO1EN2ZIQl
      WamKhobZoOvO2Q9HTYMP19mNG/rLB4uTgWZelP+20PkPIqQmV1olAAA=

  # --- CloudTAK setup script ---
  - path: /opt/scripts/setup-cloudtak.sh
    permissions: '0755'
    encoding: gz+b64
    content: |
      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
      5/Hj/wDv6RS/dFoAAA==


  # --- ADS-B setup script ---
  - path: /opt/scripts/setup-adsb.sh
    permissions: '0755'
    encoding: gz+b64
    content: |
      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
      9D/N7Lx/NRYAAA==

  # --- Setup-all orchestration ---
  - path: /opt/scripts/setup-all.sh
    permissions: '0755'
    encoding: gz+b64
    content: |
      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
      Dlx3OqAcAAA=

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
  - ufw allow 80/tcp comment 'HTTP'
  - ufw allow 443/tcp comment 'HTTPS'
  - ufw allow 8080/tcp comment 'OTS HTTP API'
  - ufw allow 8443/tcp comment 'OTS HTTPS API'
  - ufw allow 8446/tcp comment 'OTS Certificate Enrollment'
  - ufw allow 8088/tcp comment 'OTS TCP CoT'
  - ufw allow 8089/tcp comment 'OTS SSL CoT'
  - ufw allow 8554/tcp comment 'RTSP (OTS mediamtx)'
  - ufw allow 8554/udp comment 'RTSP UDP (OTS mediamtx)'
  - ufw allow 1935/tcp comment 'RTMP (OTS mediamtx)'
  - ufw allow 8888/tcp comment 'HLS (OTS mediamtx)'
  - ufw allow 8889/tcp comment 'WebRTC (OTS mediamtx)'
  - ufw allow 8189/udp comment 'WebRTC UDP'
  - ufw allow 8890/udp comment 'SRT (OTS mediamtx)'
  - ufw allow 8654/tcp comment 'CloudTAK RTSP'
  - ufw allow 2935/tcp comment 'CloudTAK RTMP'
  - ufw allow 8988/tcp comment 'CloudTAK HLS'
  - ufw allow 8990/udp comment 'CloudTAK SRT'
  - ufw allow 9898/tcp comment 'CloudTAK Media API'
  - ufw allow 64738/tcp comment 'Mumble TCP'
  - ufw allow 64738/udp comment 'Mumble UDP'
  - ufw --force enable

  # ── Fail2ban ──
  - systemctl enable fail2ban
  - systemctl start fail2ban

  # ── ipsum blocklist (block known malicious IPs) ──
  - bash /opt/ipsum.sh
  - echo '0 0 * * * /opt/ipsum.sh' | crontab -

  # ── Automatic installation ──
  - bash /opt/scripts/setup-all.sh

final_message: |
  ===========================================
   TAK Server ready! Time: $UPTIME seconds
   SSH: ssh tak@{{OTS_DOMAIN}}
   Log: /var/log/tak-setup.log
  ===========================================
