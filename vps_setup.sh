#!/bin/bash

# =============================================================================
# VPS Setup Script - Python/Docker Multi-App Server (v3 - hardened)
# Tested target: Ubuntu 24.04 (Noble)
#
# Safety properties:
#  - SSH KEY auth (a forgotten password never locks you out); key is validated
#  - SSH port set the Ubuntu-24.04 way (ssh.socket), bound on BOTH IPv4 + IPv6
#  - VERIFIES an IPv4 listener on the port BEFORE closing the firewall or
#    disabling root. If it's missing, port 22 stays open and root stays enabled.
#  - Step 7 runs without 'set -e' so it can never half-apply and lock you out
#  - Self-check at the end grades the whole setup PASS/FAIL
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_step()    { echo -e "\n${BLUE}===> $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }

# 'set -e' protects the INSTALL steps (1-6): a real failure there should stop.
# It is deliberately turned OFF before Step 7 (the SSH/firewall part) so that
# block always runs to completion and never leaves you half-locked-out.
set -e

if [ "$EUID" -ne 0 ]; then
  print_error "Please run as root: bash vps_setup.sh"
  exit 1
fi

clear
echo -e "${BLUE}"
echo "=============================================="
echo "   VPS Setup Script v3 - hardened             "
echo "=============================================="
echo -e "${NC}"
print_warning "Keep your Contabo rescue/console access handy, just in case."
echo ""
read -p "Press ENTER to continue or CTRL+C to cancel..."

# -----------------------------------------------------------------------------
# INPUT
# -----------------------------------------------------------------------------
print_step "Configuration"

while true; do
  read -p "Enter new username to create: " NEW_USER
  [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
  print_error "Invalid username. Lowercase letters, numbers, hyphens only."
done

while true; do
  read -s -p "Enter password for $NEW_USER: " NEW_PASS; echo ""
  read -s -p "Confirm password: " NEW_PASS2; echo ""
  [ -n "$NEW_PASS" ] || { print_error "Password cannot be empty."; continue; }
  [ "$NEW_PASS" = "$NEW_PASS2" ] && break
  print_error "Passwords do not match."
done

echo ""
print_warning "STRONGLY recommended: paste your SSH PUBLIC key."
echo "  On your Mac:  cat ~/.ssh/id_ed25519.pub   (copy the whole single line)"
echo "This is your lockout-proof way in. Leave blank to skip (not advised)."
# Validate the key so a bad paste can't silently write a broken authorized_keys.
while true; do
  read -r -p "Paste public key (or ENTER to skip): " PUBKEY
  [ -z "$PUBKEY" ] && break
  if [[ "$PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-)[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
    break
  fi
  print_error "That doesn't look like a valid public key (must start with ssh-ed25519, ssh-rsa, ...). Re-paste, or press ENTER to skip."
done

while true; do
  read -p "SSH port (ENTER = keep 22, or 1024-65535): " SSH_PORT
  if [ -z "$SSH_PORT" ]; then SSH_PORT=22; break; fi
  { [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1024 ] && [ "$SSH_PORT" -le 65535 ]; } && break
  print_error "Invalid port."
done

DISABLE_ROOT="no"
if [ -n "$PUBKEY" ]; then
  read -p "Disable root SSH login after setup? Only safe if your key works (yes/no) [no]: " DR
  [ "$DR" = "yes" ] && DISABLE_ROOT="yes"
fi

echo ""
echo -e "${YELLOW}--- Summary ---${NC}"
echo "  User:             $NEW_USER"
echo "  SSH key:          $([ -n "$PUBKEY" ] && echo 'provided (validated)' || echo 'NONE (password only)')"
echo "  SSH port:         $SSH_PORT"
echo "  Disable root SSH: $DISABLE_ROOT"
echo ""
read -p "Proceed? (yes/no): " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 0; }

# -----------------------------------------------------------------------------
# 1. UPDATE
# -----------------------------------------------------------------------------
print_step "Step 1/7 - Updating system"
apt update -y && apt upgrade -y
apt autoremove -y
print_success "System updated"

# -----------------------------------------------------------------------------
# 2. TOOLS
# -----------------------------------------------------------------------------
print_step "Step 2/7 - Essential tools"
apt install -y curl wget git unzip zip build-essential software-properties-common \
  apt-transport-https ca-certificates gnupg lsb-release htop nano fail2ban ufw \
  logrotate cron
print_success "Tools installed"

# -----------------------------------------------------------------------------
# 3. USER + SSH KEY
# -----------------------------------------------------------------------------
print_step "Step 3/7 - Creating user $NEW_USER"
if id "$NEW_USER" &>/dev/null; then
  print_warning "User exists, skipping create"
else
  adduser --disabled-password --gecos "" "$NEW_USER"
  echo "$NEW_USER:$NEW_PASS" | chpasswd
fi
usermod -aG sudo "$NEW_USER"

if [ -n "$PUBKEY" ]; then
  install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" /home/$NEW_USER/.ssh
  echo "$PUBKEY" > /home/$NEW_USER/.ssh/authorized_keys
  chmod 600 /home/$NEW_USER/.ssh/authorized_keys
  chown "$NEW_USER:$NEW_USER" /home/$NEW_USER/.ssh/authorized_keys
  install -d -m 700 /root/.ssh
  echo "$PUBKEY" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  print_success "SSH key installed for $NEW_USER (and root as backup)"
fi
print_success "User ready"

# -----------------------------------------------------------------------------
# 4. DOCKER
# -----------------------------------------------------------------------------
print_step "Step 4/7 - Docker"
apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker && systemctl start docker
usermod -aG docker "$NEW_USER"
print_success "Docker: $(docker --version)"

# -----------------------------------------------------------------------------
# 5. NGINX
# -----------------------------------------------------------------------------
print_step "Step 5/7 - Nginx"
apt install -y nginx
systemctl enable nginx && systemctl start nginx
print_success "Nginx installed"

# -----------------------------------------------------------------------------
# 6. PYTHON
# -----------------------------------------------------------------------------
print_step "Step 6/7 - Python tools"
apt install -y python3 python3-pip python3-venv python3-dev
pip3 install --upgrade pip --break-system-packages || true
print_success "Python: $(python3 --version)"

# =============================================================================
# 7. SSH HARDENING  --  'set -e' OFF from here so this block cannot half-apply
# =============================================================================
set +e
print_step "Step 7/7 - SSH, firewall, fail2ban"

# Our settings as a high-priority drop-in (99 sorts last = wins over cloud-image
# files like 60-cloudimg-settings.conf which can disable PasswordAuthentication).
cat > /etc/ssh/sshd_config.d/99-zzz-custom.conf << EOF
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin yes
LoginGraceTime 30
MaxAuthTries 5
EOF

# Set the port on the SOCKET (the thing that actually controls the port under
# socket activation on Ubuntu 24.04), binding BOTH IPv4 and IPv6 explicitly.
# A bare "ListenStream=PORT" can come up IPv6-only on some cloud images, which
# makes IPv4 clients get "connection refused" -- the bug that caused real pain.
if systemctl list-unit-files | grep -q '^ssh\.socket'; then
  mkdir -p /etc/systemd/system/ssh.socket.d
  {
    echo "[Socket]"
    echo "ListenStream="
    echo "ListenStream=0.0.0.0:$SSH_PORT"
    echo "ListenStream=[::]:$SSH_PORT"
  } > /etc/systemd/system/ssh.socket.d/override.conf
  systemctl daemon-reload
  systemctl restart ssh.socket
  systemctl restart ssh 2>/dev/null
else
  sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
  grep -q "^Port " /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
  systemctl enable ssh
  systemctl restart ssh
fi

# --- VERIFY an IPv4 listener on the port BEFORE locking anything down ---
sleep 2
if ss -4 -tlnp 2>/dev/null | grep -q ":$SSH_PORT "; then
  PORT_OK="yes"
  print_success "sshd is listening on IPv4 port $SSH_PORT"
else
  PORT_OK="no"
  print_error "sshd is NOT on IPv4 port $SSH_PORT -- keeping port 22 open and root enabled so you are not locked out."
fi

# --- Firewall ---
ufw allow 80/tcp  comment "HTTP"  >/dev/null 2>&1
ufw allow 443/tcp comment "HTTPS" >/dev/null 2>&1
ufw allow "$SSH_PORT/tcp" comment "SSH" >/dev/null 2>&1
if [ "$PORT_OK" = "no" ] && [ "$SSH_PORT" != "22" ]; then
  ufw allow 22/tcp comment "SSH-fallback" >/dev/null 2>&1
  print_warning "Kept port 22 open as a fallback."
fi
ufw default deny incoming  >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
print_success "UFW enabled"

# --- Root login: disable ONLY if key set, port verified, and user opted in ---
if [ "$DISABLE_ROOT" = "yes" ] && [ -n "$PUBKEY" ] && [ "$PORT_OK" = "yes" ]; then
  sed -i 's/^PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config.d/99-zzz-custom.conf
  systemctl restart ssh 2>/dev/null || systemctl restart ssh.socket 2>/dev/null
  ROOT_STATE="disabled"
  print_success "Root SSH login disabled"
else
  ROOT_STATE="ENABLED"
  print_warning "Root SSH login LEFT ENABLED (safer until you confirm your key login works)."
fi

# --- Fail2ban (note: ignoreip whitelists localhost; add your home IP if you like) ---
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
[sshd]
enabled  = true
port     = $SSH_PORT
maxretry = 5
bantime  = 1h
EOF
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
print_success "Fail2ban active on port $SSH_PORT"

mkdir -p /home/$NEW_USER/apps
chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/apps

# =============================================================================
# SELF-CHECK  --  grade the setup before you trust it
# =============================================================================
print_step "Self-check"
PASS=0; FAIL=0
check() { # desc, condition-cmd
  if eval "$2" >/dev/null 2>&1; then echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS+1));
  else echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); fi
}

check "SSH listening on IPv4 port $SSH_PORT"   "ss -4 -tlnp | grep -q ':$SSH_PORT '"
check "SSH listening on IPv6 port $SSH_PORT"   "ss -6 -tlnp | grep -q ':$SSH_PORT '"
check "UFW active"                              "ufw status | grep -q 'Status: active'"
check "UFW allows $SSH_PORT"                    "ufw status | grep -q '$SSH_PORT'"
check "fail2ban running"                        "systemctl is-active --quiet fail2ban"
check "docker running"                          "systemctl is-active --quiet docker"
check "nginx running"                           "systemctl is-active --quiet nginx"
check "$NEW_USER in sudo group"                 "id -nG $NEW_USER | grep -qw sudo"
check "$NEW_USER in docker group"               "id -nG $NEW_USER | grep -qw docker"
if [ -n "$PUBKEY" ]; then
  check "authorized_keys present for $NEW_USER" "test -s /home/$NEW_USER/.ssh/authorized_keys"
fi
check "sshd config syntax valid"                "sshd -t"

# -----------------------------------------------------------------------------
# SUMMARY
# -----------------------------------------------------------------------------
echo ""
echo -e "${GREEN}=============== Setup Complete ($PASS passed, $FAIL failed) ===============${NC}"
echo "  Login:    ssh -p $SSH_PORT $NEW_USER@YOUR_SERVER_IP"
echo "  IPv4 :$SSH_PORT listening: $PORT_OK"
echo "  Root SSH: $ROOT_STATE"
echo ""
if [ "$FAIL" -gt 0 ]; then
  print_warning "Some checks FAILED above -- review them before closing this session."
fi
echo -e "${RED}DO THIS NOW, before closing this session:${NC}"
echo "  1) Open a NEW terminal and confirm:  ssh -p $SSH_PORT $NEW_USER@YOUR_SERVER_IP"
echo "  2) A kernel update may have been installed (you'll see 'restart required')."
echo "     Reboot deliberately:  sudo reboot   -- then re-test the login above."
echo "  3) Only after the post-reboot login works are you truly done."
echo ""