#!/bin/bash

# =============================================================================
# VPS Setup Script - Python/Docker Multi-App Server
# Tested on: Ubuntu 22.04 / Debian 12
# =============================================================================

set -e  # Exit immediately if any command fails

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step()    { echo -e "\n${BLUE}===> $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }

# =============================================================================
# MUST RUN AS ROOT
# =============================================================================
if [ "$EUID" -ne 0 ]; then
  print_error "Please run as root: bash vps_setup.sh"
  exit 1
fi

# =============================================================================
# WELCOME
# =============================================================================
clear
echo -e "${BLUE}"
echo "=============================================="
echo "   VPS Setup Script - Python/Docker Server   "
echo "=============================================="
echo -e "${NC}"
echo "This script will:"
echo "  - Update your server"
echo "  - Create a new sudo user"
echo "  - Change SSH port"
echo "  - Setup UFW firewall + Fail2ban"
echo "  - Install Docker + Docker Compose"
echo "  - Install Nginx"
echo "  - Install Python 3 tools"
echo ""
print_warning "Keep your Contabo VNC console open as a backup!"
echo ""
read -p "Press ENTER to continue or CTRL+C to cancel..."

# =============================================================================
# COLLECT USER INPUT
# =============================================================================
print_step "Configuration"

# Username
while true; do
  read -p "Enter new username to create: " NEW_USER
  if [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    break
  else
    print_error "Invalid username. Use lowercase letters, numbers, hyphens only."
  fi
done

# Password
while true; do
  read -s -p "Enter password for $NEW_USER: " NEW_PASS
  echo ""
  read -s -p "Confirm password: " NEW_PASS2
  echo ""
  if [ "$NEW_PASS" = "$NEW_PASS2" ]; then
    break
  else
    print_error "Passwords do not match. Try again."
  fi
done

# SSH Port
while true; do
  read -p "Enter new SSH port (recommended: 2222, range: 1024-65535): " SSH_PORT
  if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1024 ] && [ "$SSH_PORT" -le 65535 ]; then
    break
  else
    print_error "Invalid port. Must be between 1024 and 65535."
  fi
done

# Summary
echo ""
echo -e "${YELLOW}--- Configuration Summary ---${NC}"
echo "  Username: $NEW_USER"
echo "  SSH Port: $SSH_PORT"
echo ""
read -p "Confirm and proceed? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

# =============================================================================
# STEP 1 - UPDATE & UPGRADE
# =============================================================================
print_step "Step 1/7 - Updating system packages"
apt update -y && apt upgrade -y
apt autoremove -y
print_success "System updated"

# =============================================================================
# STEP 2 - INSTALL ESSENTIAL TOOLS
# =============================================================================
print_step "Step 2/7 - Installing essential tools"
apt install -y \
  curl wget git unzip zip \
  build-essential \
  software-properties-common \
  apt-transport-https \
  ca-certificates \
  gnupg \
  lsb-release \
  htop \
  nano \
  fail2ban \
  ufw \
  logrotate \
  cron
print_success "Essential tools installed"

# =============================================================================
# STEP 3 - CREATE USER
# =============================================================================
print_step "Step 3/7 - Creating user: $NEW_USER"

if id "$NEW_USER" &>/dev/null; then
  print_warning "User $NEW_USER already exists, skipping creation"
else
  adduser --disabled-password --gecos "" "$NEW_USER"
  echo "$NEW_USER:$NEW_PASS" | chpasswd
  print_success "User $NEW_USER created"
fi

usermod -aG sudo "$NEW_USER"
print_success "$NEW_USER added to sudo group"

# =============================================================================
# STEP 4 - INSTALL DOCKER
# =============================================================================
print_step "Step 4/7 - Installing Docker"

# Remove old versions if any
apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Add Docker's official GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Add Docker repo
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl start docker

# Allow new user to run docker without sudo
usermod -aG docker "$NEW_USER"

print_success "Docker installed: $(docker --version)"
print_success "Docker Compose installed: $(docker compose version)"

# =============================================================================
# STEP 5 - INSTALL NGINX
# =============================================================================
print_step "Step 5/7 - Installing Nginx"
apt install -y nginx
systemctl enable nginx
systemctl start nginx
print_success "Nginx installed: $(nginx -v 2>&1)"

# =============================================================================
# STEP 6 - INSTALL PYTHON TOOLS
# =============================================================================
print_step "Step 6/7 - Installing Python tools"
apt install -y python3 python3-pip python3-venv python3-dev
pip3 install --upgrade pip --break-system-packages || true
print_success "Python: $(python3 --version)"
print_success "pip: $(pip3 --version)"

# =============================================================================
# STEP 7 - SSH + FIREWALL + FAIL2BAN
# =============================================================================
print_step "Step 7/7 - Configuring SSH, UFW, and Fail2ban"

# --- SSH ---
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup.$(date +%Y%m%d%H%M%S)"

# Set port
sed -i "s/^#*Port .*/Port $SSH_PORT/" "$SSHD_CONFIG"
grep -q "^Port " "$SSHD_CONFIG" || echo "Port $SSH_PORT" >> "$SSHD_CONFIG"

# Disable root login
sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" "$SSHD_CONFIG"
grep -q "^PermitRootLogin " "$SSHD_CONFIG" || echo "PermitRootLogin no" >> "$SSHD_CONFIG"

# Enable password auth
sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication yes/" "$SSHD_CONFIG"
grep -q "^PasswordAuthentication " "$SSHD_CONFIG" || echo "PasswordAuthentication yes" >> "$SSHD_CONFIG"

# Reduce attack surface
sed -i "s/^#*LoginGraceTime .*/LoginGraceTime 30/" "$SSHD_CONFIG"
grep -q "^LoginGraceTime " "$SSHD_CONFIG" || echo "LoginGraceTime 30" >> "$SSHD_CONFIG"

sed -i "s/^#*MaxAuthTries .*/MaxAuthTries 3/" "$SSHD_CONFIG"
grep -q "^MaxAuthTries " "$SSHD_CONFIG" || echo "MaxAuthTries 3" >> "$SSHD_CONFIG"

# CRITICAL: enable service before disabling socket (prevents lockout on reboot)
systemctl enable ssh
systemctl disable ssh.socket 2>/dev/null || true
systemctl stop ssh.socket 2>/dev/null || true
systemctl restart ssh

print_success "SSH configured on port $SSH_PORT, root login disabled"

# --- UFW ---
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp"  comment "SSH"
ufw allow 80/tcp           comment "HTTP"
ufw allow 443/tcp          comment "HTTPS"
ufw --force enable
print_success "UFW firewall enabled"

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
maxretry = 3
bantime  = 24h
EOF

systemctl enable fail2ban
systemctl restart fail2ban
print_success "Fail2ban configured (3 wrong attempts = 24h ban)"

# =============================================================================
# CREATE DIRECTORY STRUCTURE
# =============================================================================
mkdir -p /home/$NEW_USER/apps
chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/apps
print_success "Created /home/$NEW_USER/apps — deploy your Docker apps here"

# =============================================================================
# FINAL SUMMARY
# =============================================================================
echo ""
echo -e "${GREEN}"
echo "=============================================="
echo "            Setup Complete!"
echo "=============================================="
echo -e "${NC}"
echo -e "${YELLOW}Installed:${NC}"
echo "  ✓ Docker:         $(docker --version)"
echo "  ✓ Docker Compose: $(docker compose version)"
echo "  ✓ Nginx:          $(nginx -v 2>&1)"
echo "  ✓ Python:         $(python3 --version)"
echo "  ✓ Fail2ban:       active (3 attempts = 24h ban)"
echo "  ✓ UFW:            active"
echo ""
echo -e "${YELLOW}Your server details:${NC}"
echo "  SSH:  ssh -p $SSH_PORT $NEW_USER@YOUR_SERVER_IP"
echo "  Apps: /home/$NEW_USER/apps/"
echo ""
echo -e "${RED}IMPORTANT - Before closing this session:${NC}"
echo "  Open a NEW terminal and test login first:"
echo "  ssh -p $SSH_PORT $NEW_USER@YOUR_SERVER_IP"
echo ""
echo -e "${YELLOW}To re-enable root login in future (as $NEW_USER):${NC}"
echo "  sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config"
echo "  sudo systemctl restart ssh"
echo ""
