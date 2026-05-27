# vps_setup.sh

A one-shot bash script to provision a fresh Ubuntu 24.04 VPS for deploying multiple Python/Docker applications.

## What It Does

Runs 7 steps sequentially, asking for your input before starting:

| Step | What happens |
|------|-------------|
| 1 | System update & upgrade |
| 2 | Installs essential tools (git, curl, build-essential, fail2ban, etc.) |
| 3 | Creates a new sudo user |
| 4 | Installs Docker + Docker Compose |
| 5 | Installs Nginx |
| 6 | Installs Python 3 + pip + venv |
| 7 | Hardens SSH, configures UFW firewall, configures Fail2ban |

## Requirements

- Fresh Ubuntu 24.04 VPS
- Root access
- SSH into server as `root`

## Usage

**Upload to your server:**
```bash
scp vps_setup.sh root@YOUR_SERVER_IP:/root/
```

**SSH in:**
```bash
ssh root@YOUR_SERVER_IP
```

**Run:**
```bash
bash vps_setup.sh
```

## Interactive Prompts

The script will ask you for:

- **Username** — new sudo user to create (e.g. `farhan`)
- **Password** — password for that user (entered twice to confirm)
- **SSH Port** — custom port to replace default 22 (e.g. `2222`, range: 1024–65535)

A summary is shown before anything runs — you can cancel at that point.

## After Running

Test your new SSH login **before closing your root session**:
```bash
ssh -p YOUR_PORT USERNAME@YOUR_SERVER_IP
```

Then reboot to apply any pending kernel updates:
```bash
sudo reboot
```

After reboot, verify everything is running:
```bash
sudo systemctl status ssh nginx docker fail2ban
sudo ufw status
```

## What Gets Installed

| Tool | Purpose |
|------|---------|
| Docker + Docker Compose | Run containerised Python apps |
| Nginx | Reverse proxy — routes traffic to your apps |
| Python 3 + pip + venv | Python runtime and virtual environments |
| UFW | Firewall — only ports 22(SSH), 80, 443 open |
| Fail2ban | Blocks brute force — 3 wrong attempts = 24h ban |
| git, curl, wget, unzip | General utilities |
| build-essential | C compiler tools (needed by some Python packages) |

## Security Hardening Applied

- SSH moved to custom port
- Root login disabled (`PermitRootLogin no`)
- Login grace time reduced to 30 seconds
- Max auth attempts set to 3
- `ssh.socket` disabled (prevents port reverting to 22 on reboot)
- UFW default deny incoming
- Fail2ban watching SSH with 24h ban

## Re-enable Root Login

If you ever need root SSH access again, log in as your user and run:
```bash
sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

## Directory Structure Created

```
/home/USERNAME/
└── apps/        ← deploy your Docker apps here
```

## Tested On

- Ubuntu 24.04 LTS (Noble)
- Contabo VPS
