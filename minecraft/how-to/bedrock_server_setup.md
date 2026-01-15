# Minecraft Bedrock Server Setup on Ubuntu

Complete instructions to set up a Bedrock server alongside an existing Java server on Oracle Cloud Ubuntu.

## Prerequisites & Planning

**Resource Allocation:**
- Java server typically uses 4-6 GB RAM
- Bedrock server uses 2-4 GB RAM
- Allocate: 6 GB to Java, 4 GB to Bedrock, 2 GB system buffer
- Use different ports: Java (25565), Bedrock (19132 UDP/19133 TCP)

**System Requirements:**
- Ubuntu 20.04 LTS or later
- Sufficient disk space (10+ GB recommended)
- Open ports in firewall
- 12 GB RAM, 2 vCPUs (Oracle-free tier)

---

## Step 1: Install Prerequisites

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y wget curl unzip libssl-dev tzdata
```

---

## Step 2: Create Bedrock Server Directory

```bash
mkdir -p ~/bedrock-server
cd ~/bedrock-server
```

---

## Step 3: Download Bedrock Server

Get the latest version from Microsoft:

```bash
# Check the latest version at: https://www.minecraft.net/en-us/download/server/bedrock/
# Download (example version - check for latest):
wget https://launcher.mojang.com/v1/objects/[LATEST-HASH]/bedrock-server-[VERSION].zip

# Or use a generic approach:
LATEST_URL=$(curl -s "https://launcher.mojang.com/v1/objects/" 2>/dev/null | grep -o '"bedrock-server[^"]*' | head -1)
wget "https://launcher.mojang.com/v1/objects/${LATEST_URL}"
```

---

## Step 4: Extract & Configure

```bash
unzip -o bedrock-server-*.zip
rm bedrock-server-*.zip

# Make startup script executable
chmod +x bedrock_server
```

---

## Step 5: Configure Server Properties

Edit `server.properties`:

```bash
nano server.properties
```

**Critical settings to modify:**

```properties
# Server name
server-name=Your Bedrock Server Name

# MOTD (message of the day)
level-name=Bedrock World

# Game mode (Survival=0, Creative=1, Adventure=2)
gamemode=0

# Difficulty (Peaceful=0, Easy=1, Normal=2, Hard=3)
difficulty=2

# Max players (adjust based on your hardware)
max-players=20

# Memory allocation (set lower since Java uses more)
# Note: Bedrock doesn't have direct Java heap settings
# But you'll manage system-wide memory

# PvP and other gameplay settings
pvp=true
player-idle-timeout=30
```

---

## Step 6: Configure Firewall (UFW)

```bash
# Allow Bedrock ports
sudo ufw allow 19132/udp
sudo ufw allow 19133/tcp

# Verify
sudo ufw status
```

---

## Step 7: Set Up Systemd Service

Create a systemd service file for automatic startup/restart:

```bash
sudo nano /etc/systemd/system/bedrock-server.service
```

Add this content:

```ini
[Unit]
Description=Minecraft Bedrock Server
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/bedrock-server
ExecStart=/home/ubuntu/bedrock-server/bedrock_server
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Resource limits
MemoryLimit=4G
CPUQuota=50%

[Install]
WantedBy=multi-user.target
```

**Enable & start the service:**

```bash
sudo systemctl daemon-reload
sudo systemctl enable bedrock-server
sudo systemctl start bedrock-server

# Check status
sudo systemctl status bedrock-server
```

---

## Step 8: Manage Java Server Memory

Adjust your Java server startup to use 6 GB instead of default:

```bash
# Edit your Java server startup script
# Example: if using a start.sh script
java -Xmx6G -Xms6G -jar server.jar nogui

# Or create a separate launch wrapper
```

---

## Step 9: Port Forwarding (Oracle Cloud Console)

In your Oracle Cloud console:

1. Navigate to **Compute → Instances**
2. Select your instance → **Virtual Cloud Network**
3. Go to **Security Lists**
4. Add ingress rules:
   - **Protocol:** UDP, **Port:** 19132
   - **Protocol:** TCP, **Port:** 19133
   - **CIDR:** 0.0.0.0/0

---

## Step 10: Verify Server Status

```bash
# Check if service is running
sudo systemctl status bedrock-server

# View logs
sudo journalctl -u bedrock-server -f

# Check port listening
sudo netstat -tuln | grep 1913
```

---

## Step 11: Connect & Test

**On your Minecraft Bedrock client (Windows 10/11, mobile, console):**
- Add server using your instance's public IP
- Port: 19132
- Keep "Use IPv4" enabled

---

## Important Notes & Best Practices

**Memory Management:**
```bash
# Check memory usage
free -h

# Monitor processes
top -p $(pgrep -f bedrock_server)
```

**Backups:**
```bash
# Create backup script
cat > ~/bedrock-backup.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="$HOME/bedrock-backups"
mkdir -p "$BACKUP_DIR"
DATE=$(date +%Y%m%d_%H%M%S)
tar -czf "$BACKUP_DIR/bedrock-$DATE.tar.gz" ~/bedrock-server/worlds/
EOF

chmod +x ~/bedrock-backup.sh

# Schedule daily backups via crontab
crontab -e
# Add: 0 3 * * * /home/ubuntu/bedrock-backup.sh
```

**Update Process:**
```bash
# Stop the server
sudo systemctl stop bedrock-server

# Download new version
cd ~/bedrock-server
# Download latest as in Step 3

# Extract (existing configs will be preserved)
unzip -o bedrock-server-*.zip

# Restart
sudo systemctl start bedrock-server
```

**Logging:**
```bash
# Enable server logs in server.properties
# Check logs location
ls -la ~/bedrock-server/logs/
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Server won't start | Check logs: `journalctl -u bedrock-server` |
| Can't connect | Verify firewall rules, check Oracle Security Lists |
| Out of memory | Reduce `max-players` or increase instance RAM |
| Performance lag | Reduce view distance in `server.properties` |
| Port conflict | Verify Java server isn't using 19132/19133 |

This setup allows both Java and Bedrock servers to run independently on the same instance without resource contention.
