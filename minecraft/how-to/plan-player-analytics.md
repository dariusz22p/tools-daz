# Plan Player Analytics Setup (Ubuntu)

## Overview
Plan (Player Analytics) is a powerful analytics plugin for Minecraft servers, providing web-based insights into player activity and server performance.

---

## Prerequisites
- Ubuntu server with a running Minecraft server (Spigot, Paper, or compatible)
- Java 17 or newer (`java -version`)
- SFTP/SSH access

---

## 1. Download Plan
1. Visit: https://github.com/plan-player-analytics/Plan/releases
2. Download the latest `Plan.jar` file.

---

## 2. Install Plan
1. Upload `Plan.jar` to your server's `plugins` directory:
	```sh
	sftp user@your-server
	put Plan.jar /path/to/minecraft/plugins/
	```
2. Restart your Minecraft server:
	```sh
	systemctl restart minecraft
	# or use your server's start script
	```

---

## 3. Initial Configuration
1. On first start, Plan creates a `Plan` folder in `plugins/`.
2. Edit `plugins/Plan/config.yml` to adjust settings (optional).

---

## 4. Access the Web UI
1. Check the server log for the web address (default: `http://your-server-ip:8804`).
2. Open in your browser.
3. Set up an admin account as prompted.

---

## 5. (Optional) Secure the Web UI
- Set up a reverse proxy (Nginx/Apache) for HTTPS.
- Restrict access by IP or password.

---

## 6. (Optional) Multi-server Setup
1. Install Plan on each server.
2. Configure all servers to use the same MySQL database in `config.yml`.

---

## 7. Useful Commands
- `/plan` — Main command
- `/plan info` — Plugin info
- `/plan webuser add <name> <password> <role>` — Add web users

---

## Troubleshooting
- Check `logs/Plan/latest.log` for errors.
- Ensure Java version is correct.
- Verify firewall allows port 8804 (or your configured port).

---

## Links
- [Plan Documentation](https://planplayer.com/wiki/)
- [GitHub Releases](https://github.com/plan-player-analytics/Plan/releases)
