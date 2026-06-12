#!/bin/bash

# =============================================================================
# VPS Setup Script - Python/Docker Multi-App Server (v2 - lockout-safe)
# Tested target: Ubuntu 24.04 (Noble)
#
# Key safety properties:
#  - Sets up SSH KEY auth (so a forgotten password never locks you out)
#  - Changes the SSH port the Ubuntu-24.04-correct way (ssh.socket override)
#  - VERIFIES sshd is listening on the new port BEFORE closing the firewall
#    or touching root login. If it's not listening, it leaves port 22 open
#    and root reachable, so you can always get back in.
#  - Root login left ENABLED by default (opt-in to disable)
# =============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_step()    { echo -e "\n${BLUE}===> $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }

if [ "$EUID" -ne 0 ]; then
  print_error "Please run as root: bash vps_setup.sh"
  exit 1
fi

clear
echo -e "${BLUE}"
echo "=============================================="
echo "   VPS Setup Script v2 - lockout-safe         "
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
  [ "$NEW_PASS" = "$NEW_PASS2" ] && break
  print_error "Passwords do not match."
done

echo ""
print_warning "STRONGLY recommended: paste your SSH PUBLIC key (from your Mac:"
echo "  cat ~/.ssh/id_ed25519.pub   -- copy the whole line)."
echo "This is your lockout-proof way in. Leave blank to skip (not advised)."
read -r -p "Paste public key (or ENTER to skip): " PUBKEY

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
echo "  User:        $NEW_USER"
echo "  SSH key:     $([ -n "$PUBKEY" ] && echo 'provided' || echo 'NONE (password only)')"
echo "  SSH port:    $SSH_PORT"
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
  # Backup copy for root too, so you always have a second way in
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

# -----------------------------------------------------------------------------
# 7. SSH HARDENING (the careful part)
# -----------------------------------------------------------------------------
print_step "Step 7/7 - SSH, firewall, fail2ban"

# Write OUR settings as a high-priority drop-in so they win over cloud-image
# files like 60-cloudimg-settings.conf. (99 sorts last = highest precedence.)
cat > /etc/ssh/sshd_config.d/99-zzz-custom.conf << EOF
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin yes
LoginGraceTime 30
MaxAuthTries 5
EOF

# Set the port the Ubuntu-24.04 way: on the SOCKET, not just sshd_config.
# This is what actually controls the listening port under socket activation.
if systemctl list-unit-files | grep -q '^ssh\.socket'; then
  mkdir -p /etc/systemd/system/ssh.socket.d
  printf '[Socket]\nListenStream=\nListenStream=%s\n' "$SSH_PORT" > /etc/systemd/system/ssh.socket.d/override.conf
  systemctl daemon-reload
  systemctl restart ssh.socket
  systemctl restart ssh 2>/dev/null || true
else
  # Older systems without socket activation: use sshd_config + service
  sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
  grep -q "^Port " /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
  systemctl enable ssh
  systemctl restart ssh
fi

# --- VERIFY sshd is actually listening on the new port BEFORE we lock anything ---
sleep 2
if ss -tlnp 2>/dev/null | grep -q ":$SSH_PORT "; then
  PORT_OK="yes"
  print_success "sshd is listening on port $SSH_PORT"
else
  PORT_OK="no"
  print_error "sshd is NOT listening on $SSH_PORT — leaving port 22 open and root enabled so you are not locked out."
fi

# --- Firewall: only fully lock down if the new port verified ---
ufw allow 80/tcp  comment "HTTP"  >/dev/null
ufw allow 443/tcp comment "HTTPS" >/dev/null
ufw allow "$SSH_PORT/tcp" comment "SSH" >/dev/null
if [ "$PORT_OK" = "no" ] && [ "$SSH_PORT" != "22" ]; then
  ufw allow 22/tcp comment "SSH-fallback" >/dev/null
  print_warning "Kept port 22 open as a fallback."
fi
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable
print_success "UFW enabled"

# --- Root login: only disable if a key was set AND port verified AND user opted in ---
if [ "$DISABLE_ROOT" = "yes" ] && [ -n "$PUBKEY" ] && [ "$PORT_OK" = "yes" ]; then
  sed -i 's/^PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config.d/99-zzz-custom.conf
  systemctl restart ssh 2>/dev/null || systemctl restart ssh.socket 2>/dev/null || true
  print_success "Root SSH login disabled"
else
  print_warning "Root SSH login LEFT ENABLED (safer until you confirm your key/login works)."
fi

# --- Fail2ban ---
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8
[sshd]
enabled  = true
port     = $SSH_PORT
maxretry = 5
bantime  = 1h
EOF
systemctl enable fail2ban && systemctl restart fail2ban
print_success "Fail2ban active on port $SSH_PORT"

mkdir -p /home/$NEW_USER/apps
chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/apps

# -----------------------------------------------------------------------------
# SUMMARY
# -----------------------------------------------------------------------------
echo ""
echo -e "${GREEN}=============== Setup Complete ===============${NC}"
echo "  Login:  ssh -p $SSH_PORT $NEW_USER@YOUR_SERVER_IP"
echo "  Listening on $SSH_PORT: $PORT_OK"
echo "  Root SSH: $([ "$DISABLE_ROOT" = "yes" ] && [ "$PORT_OK" = "yes" ] && echo disabled || echo ENABLED)"
echo ""
echo -e "${RED}DO THIS NOW, before closing this session:${NC}"
echo "  Open a NEW terminal and confirm:  ssh -p $SSH_PORT $NEW_USER@YOUR_SERVER_IP"
echo "  Only reboot once that works."
echo ""