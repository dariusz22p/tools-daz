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
https://github.com/plan-player-analytics/Plan/releases/download/5.7.3123/Plan-5.7-dev-build-3123.jar

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


---

## Exposing Plan Web UI via Nginx (HTTP/HTTPS)

### Prerequisites
- Plan running and accessible at `http://localhost:8804` on your server
- Nginx installed and running
- (For HTTPS) SSL certificate (e.g., Let's Encrypt)

---

### 1. Nginx Reverse Proxy for HTTP (port 80)

1. Edit or create your Nginx site config, e.g. `/etc/nginx/sites-available/plan`:
	```nginx
	server {
		listen 80;
		server_name your-domain.com;

		location / {
			proxy_pass http://localhost:8804;
			proxy_set_header Host $host;
			proxy_set_header X-Real-IP $remote_addr;
			proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
			proxy_set_header X-Forwarded-Proto $scheme;
		}
	}
	```
2. Enable the config:
	```sh
	sudo ln -s /etc/nginx/sites-available/plan /etc/nginx/sites-enabled/
	sudo nginx -t
	sudo systemctl reload nginx
	```

---

### 2. Nginx Reverse Proxy for HTTPS (port 443)

1. Obtain an SSL certificate (e.g., with Certbot):
	```sh
	sudo apt install certbot python3-certbot-nginx
	sudo certbot --nginx -d your-domain.com
	```
2. Certbot will update your config. If you want to do it manually, add:
	```nginx
	server {
		listen 443 ssl;
		server_name your-domain.com;

		ssl_certificate /etc/letsencrypt/live/your-domain.com/fullchain.pem;
		ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;

		location / {
			proxy_pass http://localhost:8804;
			proxy_set_header Host $host;
			proxy_set_header X-Real-IP $remote_addr;
			proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
			proxy_set_header X-Forwarded-Proto $scheme;
		}
	}
	```
3. Reload Nginx:
	```sh
	sudo systemctl reload nginx
	```

---

### 3. (Optional) Redirect HTTP to HTTPS

Add this server block to force HTTPS:
```nginx
server {
	listen 80;
	server_name your-domain.com;
	return 301 https://$host$request_uri;
}
```

---

### 4. Access Plan Web UI

- Visit `https://your-domain.com` in your browser.

---

## Links
- [Plan Documentation](https://planplayer.com/wiki/)
- [GitHub Releases](https://github.com/plan-player-analytics/Plan/releases)
