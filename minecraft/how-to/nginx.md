# NGINX Configuration Guide for Plan Player Analytics

**Setup for:** Oracle Cloud Ubuntu ARM (12GB RAM, 2 vCPU)  
**Domain:** javasnake.online  
**Backend Service:** Plan Player Analytics (Port 8804)  
**Date Created:** January 12, 2026

---

## Table of Contents

1. [Installation](#installation)
2. [SSL Certificate Setup](#ssl-certificate-setup)
3. [NGINX Configuration](#nginx-configuration)
4. [Cache Directory Setup](#cache-directory-setup)
5. [Monitoring & Troubleshooting](#monitoring--troubleshooting)
6. [Performance Tuning for ARM](#performance-tuning-for-arm)
7. [Maintenance](#maintenance)

---

## Installation

### Step 1: Update System & Install NGINX

```bash
# Update package manager
sudo apt update
sudo apt upgrade -y

# Install NGINX
sudo apt install -y nginx

# Enable NGINX to start on boot
sudo systemctl enable nginx

# Start NGINX
sudo systemctl start nginx

# Verify NGINX is running
sudo systemctl status nginx
```

**Why:** NGINX is a lightweight reverse proxy perfect for proxying to Plan and handling SSL termination. The `systemctl enable` ensures it restarts automatically after server reboots.

### Step 2: Install Certbot for SSL

```bash
# Install Certbot and NGINX plugin
sudo apt install -y certbot python3-certbot-nginx

# Verify installation
certbot --version
```

**Why:** Certbot automates SSL certificate provisioning and renewal via Let's Encrypt. The NGINX plugin automatically configures NGINX with SSL.

---

## SSL Certificate Setup

### Step 1: Obtain Initial Certificate

```bash
# Request certificate for your domain
sudo certbot certonly --nginx -d javasnake.online -d www.javasnake.online

# Follow the interactive prompts:
# - Enter your email
# - Accept Let's Encrypt terms
# - Choose redirect type (select "No redirect" initially)
```

**What happens:**
- Certificate stored in: `/etc/letsencrypt/live/javasnake.online/`
- Private key: `privkey.pem`
- Full chain: `fullchain.pem`
- DH parameters: `/etc/letsencrypt/ssl-dhparams.pem`

### Step 2: Verify Certificate Installation

```bash
# List all certificates
sudo certbot certificates

# Check certificate details
sudo openssl x509 -in /etc/letsencrypt/live/javasnake.online/fullchain.pem -text -noout | grep -A 2 "Validity\|Subject:"

# Test certificate validity
curl -I https://javasnake.online
```

**Expected output:** HTTP/2 200 status with valid certificate info.

### Step 3: Setup Auto-Renewal

```bash
# Enable auto-renewal timer
sudo systemctl enable certbot.timer
sudo systemctl start certbot.timer

# Test renewal (dry-run)
sudo certbot renew --dry-run

# Check renewal status
sudo systemctl status certbot.timer
sudo systemctl list-timers certbot.timer
```

**Why:** Certificates expire after 90 days. Certbot renews automatically 30 days before expiration.

---

## NGINX Configuration

### Step 1: Backup Original Configuration

```bash
# Backup default NGINX config
sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d)

# List backup files
sudo ls -la /etc/nginx/nginx.conf.backup.*
```

### Step 2: Create Main NGINX Configuration

Create/edit `/etc/nginx/nginx.conf`:

```bash
sudo nano /etc/nginx/nginx.conf
```

**Complete configuration file:**

```nginx
# config-version: 1.3
# Optimized for 12GB RAM, 2 vCPU Oracle Cloud ARM
# Domain: javasnake.online
# Backend: Plan Player Analytics (localhost:8804)

user www-data;
worker_processes 2;                    # Match available cores
worker_rlimit_nofile 65535;           # Max file descriptors
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;
include /etc/nginx/modules-enabled/*.conf;

events {
	worker_connections 4096;           # Connections per worker (2vCPU: 4096 is optimal)
	use epoll;                         # Linux event mechanism (most efficient)
	multi_accept on;                   # Accept multiple connections at once
}

http {
	##
	# Rate Limiting & DDoS Protection
	##

	# Limit requests per IP: 10 requests per second
	limit_req_zone $binary_remote_addr zone=general_limit:10m rate=10r/s;
	limit_req_zone $binary_remote_addr zone=api_limit:10m rate=5r/s;
	
	# Limit concurrent connections per IP: 50 connections
	limit_conn_zone $binary_remote_addr zone=addr:10m;
	limit_conn addr 50;
	
	# Limit request size to prevent abuse
	limit_req_status 429;

	##
	# Plan Player Analytics Caching
	##
	
	# Cache path for Plan responses: 50MB zone, 500MB disk, 1h inactive timeout
	proxy_cache_path /var/cache/nginx/plan levels=1:2 keys_zone=plan_cache:50m max_size=500m inactive=1h;

	# --- Plan Player Analytics Reverse Proxy ---
	# HTTP: Redirect to HTTPS
	server {
		listen 80;
		listen [::]:80;
		server_name javasnake.online;
		return 301 https://$host$request_uri;
	}

	# HTTPS: Proxy to Plan web UI
	server {
		listen 443 ssl http2;
		listen [::]:443 ssl http2;
		server_name javasnake.online;

		ssl_certificate /etc/letsencrypt/live/javasnake.online/fullchain.pem;
		ssl_certificate_key /etc/letsencrypt/live/javasnake.online/privkey.pem;
		ssl_session_timeout 1d;
		ssl_session_cache shared:SSL:64m;
		ssl_session_tickets off;
		
		# Modern configuration
		ssl_protocols TLSv1.2 TLSv1.3;
		ssl_ciphers HIGH:!aNULL:!MD5;
		ssl_prefer_server_ciphers on;

		# HSTS header (strict transport security)
		add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
		
		# Additional security headers
		add_header X-Frame-Options "SAMEORIGIN" always;
		add_header X-Content-Type-Options "nosniff" always;
		add_header X-XSS-Protection "1; mode=block" always;
		add_header Referrer-Policy "strict-origin-when-cross-origin" always;

		# Rate limiting for API-like endpoints
		location ~ ^/api/ {
			limit_req zone=api_limit burst=20 nodelay;
			
			# Cache API responses intelligently
			proxy_cache plan_cache;
			proxy_cache_valid 200 1h;
			proxy_cache_valid 404 5m;
			proxy_cache_use_stale error timeout http_500 http_502 http_503 http_504;
			proxy_cache_bypass $http_pragma $http_authorization;
			add_header X-Cache-Status $upstream_cache_status;
			
			proxy_pass http://localhost:8804;
			proxy_http_version 1.1;
			
			# Headers
			proxy_set_header Host $host;
			proxy_set_header X-Real-IP $remote_addr;
			proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
			proxy_set_header X-Forwarded-Proto $scheme;
			proxy_set_header X-Forwarded-Host $server_name;
			
			# WebSocket support
			proxy_set_header Upgrade $http_upgrade;
			proxy_set_header Connection "upgrade";
			
			# Timeouts and buffering
			proxy_connect_timeout 60s;
			proxy_send_timeout 60s;
			proxy_read_timeout 60s;
			proxy_request_buffering off;
			proxy_buffering off;
			
			# Don't proxy unnecessary headers
			proxy_hide_header Server;
		}

		location / {
			limit_req zone=general_limit burst=30 nodelay;
			
			# Cache static assets aggressively
			location ~* \.(js|css|svg|ico|woff|woff2|ttf|eot)$ {
				proxy_pass http://localhost:8804;
				proxy_cache plan_cache;
				proxy_cache_valid 200 30d;
				proxy_cache_use_stale error timeout;
				add_header Cache-Control "public, immutable, max-age=2592000";
				add_header X-Cache-Status $upstream_cache_status;
				access_log off;
			}
			
			# Cache HTML minimally
			location ~* \.html?$ {
				proxy_pass http://localhost:8804;
				proxy_cache plan_cache;
				proxy_cache_valid 200 30m;
				add_header Cache-Control "public, max-age=1800";
				add_header X-Cache-Status $upstream_cache_status;
			}
			
			# Default caching for other requests
			proxy_cache plan_cache;
			proxy_cache_valid 200 10m;
			proxy_cache_use_stale error timeout http_500 http_502 http_503 http_504;
			add_header X-Cache-Status $upstream_cache_status;
			
			proxy_pass http://localhost:8804;
			proxy_http_version 1.1;
			
			# Headers
			proxy_set_header Host $host;
			proxy_set_header X-Real-IP $remote_addr;
			proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
			proxy_set_header X-Forwarded-Proto $scheme;
			proxy_set_header X-Forwarded-Host $server_name;
			
			# WebSocket support
			proxy_set_header Upgrade $http_upgrade;
			proxy_set_header Connection "upgrade";
			
			# Timeouts and buffering
			proxy_connect_timeout 60s;
			proxy_send_timeout 60s;
			proxy_read_timeout 60s;
			proxy_request_buffering off;
			proxy_buffering off;
			
			# Don't proxy unnecessary headers
			proxy_hide_header Server;
		}
	}

	##
	# Basic Settings
	##

	sendfile on;
	tcp_nopush on;
	tcp_nodelay on;
	keepalive_timeout 65;
	types_hash_max_size 2048;
	client_max_body_size 20M;
	server_tokens off;
	
	# Proxy buffer settings for ARM system with 12GB RAM
	proxy_buffer_size 4k;
	proxy_buffers 8 4k;
	proxy_busy_buffers_size 8k;

	include /etc/nginx/mime.types;
	default_type application/octet-stream;

	##
	# SSL Settings
	##

	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_prefer_server_ciphers on;

	##
	# Logging Settings
	##

	log_format main '$remote_addr - $remote_user [$time_local] "$request" '
	                 '$status $body_bytes_sent "$http_referer" '
	                 '"$http_user_agent" "$http_x_forwarded_for"';

	access_log /var/log/nginx/access.log main buffer=32k flush=5s;

	##
	# Gzip Settings - Optimized for ARM 2 vCPU
	##

	gzip on;
	gzip_vary on;
	gzip_proxied any;
	gzip_comp_level 4;                 # Reduced from 6 for ARM (saves CPU)
	gzip_min_length 512;               # Don't compress very small responses
	gzip_buffers 32 8k;                # Increase buffers for throughput
	gzip_http_version 1.1;
	gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
	gzip_disable "msie6";

	##
	# Virtual Host Configs
	##

	include /etc/nginx/conf.d/*.conf;
	include /etc/nginx/sites-enabled/*;
}
```

### Step 3: Test NGINX Configuration

```bash
# Syntax check (CRITICAL - do this before reloading)
sudo nginx -t

# Expected output:
# nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
# nginx: configuration file /etc/nginx/nginx.conf test is successful
```

**DO NOT reload if syntax check fails!**

### Step 4: Reload NGINX

```bash
# Gracefully reload (doesn't disconnect active connections)
sudo systemctl reload nginx

# Verify it's running
sudo systemctl status nginx

# Check if listening on ports 80 and 443
sudo ss -tlnp | grep nginx
# Should show:
# LISTEN    0        511          0.0.0.0:80          0.0.0.0:*    users:(("nginx",pid=XXX...
# LISTEN    0        511          0.0.0.0:443         0.0.0.0:*    users:(("nginx",pid=XXX...
```

---

## Cache Directory Setup

### Step 1: Create Cache Directory

```bash
# Create directory with proper permissions
sudo mkdir -p /var/cache/nginx/plan

# Set ownership to www-data (NGINX user)
sudo chown www-data:www-data /var/cache/nginx/plan

# Set permissions (755 = rwxr-xr-x)
sudo chmod 755 /var/cache/nginx/plan

# Verify
sudo ls -ld /var/cache/nginx/plan
```

**Expected output:** `drwxr-xr-x ... www-data www-data ... /var/cache/nginx/plan`

### Step 2: Monitor Cache Performance

```bash
# Watch cache hits in real-time
tail -f /var/log/nginx/access.log | grep -o 'X-Cache-Status: [^ ]*' | sort | uniq -c

# Or with timestamp
tail -f /var/log/nginx/access.log | while read line; do echo "$(date '+%H:%M:%S') $line"; done | grep X-Cache
```

**Cache status meanings:**
- `HIT` - Response served from cache (best performance)
- `MISS` - Not in cache, fetched from Plan backend
- `EXPIRED` - Cache entry was stale
- `BYPASS` - Authorization header present, cache bypassed

---

## Monitoring & Troubleshooting

### Check NGINX Status

```bash
# View NGINX process info
ps aux | grep nginx

# Check NGINX version and modules
nginx -v
nginx -V  # Shows all compiled modules

# View active connections
sudo ss -tlnp | grep nginx
```

### Monitor Real-time Traffic

```bash
# Watch access log with colors
sudo tail -f /var/log/nginx/access.log | grep --color=always .

# Count requests per second
sudo tail -f /var/log/nginx/access.log | pv -l >/dev/null

# Find slow requests (>1 second)
sudo grep -E ' [1-9][0-9]{3,}[0-9]{0,3} ' /var/log/nginx/access.log
```

### Check NGINX Error Log

```bash
# View recent errors
sudo tail -50 /var/log/nginx/error.log

# Watch errors in real-time
sudo tail -f /var/log/nginx/error.log

# Count errors by type
sudo awk '{print $NF}' /var/log/nginx/error.log | sort | uniq -c | sort -rn
```

### Verify Proxy Connection to Plan

```bash
# Check if Plan is accessible on port 8804
curl -I http://localhost:8804

# Test through HTTPS reverse proxy
curl -I https://javasnake.online

# Check DNS resolution
nslookup javasnake.online

# Trace connection path
curl -v https://javasnake.online 2>&1 | head -30
```

### Troubleshoot Common Issues

**Issue: "Connection refused" to Plan backend**
```bash
# Check if Plan is running
sudo lsof -i :8804

# Check if listening
sudo netstat -tlnp | grep 8804

# Restart Plan service
sudo systemctl restart plan  # (or your Plan service name)
```

**Issue: SSL certificate error**
```bash
# Check certificate validity
sudo openssl x509 -in /etc/letsencrypt/live/javasnake.online/fullchain.pem -noout -dates

# Verify key and cert match
sudo openssl x509 -noout -modulus -in /etc/letsencrypt/live/javasnake.online/fullchain.pem | openssl md5
sudo openssl rsa -noout -modulus -in /etc/letsencrypt/live/javasnake.online/privkey.pem | openssl md5
# Both should produce same hash
```

**Issue: High memory or CPU usage**
```bash
# Monitor NGINX processes
watch -n 1 'ps aux | grep nginx'

# Check system resources
free -h
top -p $(pgrep -d, nginx)
```

---

## Performance Tuning for ARM

### Why These Settings for ARM 12GB/2vCPU?

| Setting | Value | Reason |
|---------|-------|--------|
| `worker_processes` | 2 | Match number of CPU cores |
| `worker_connections` | 4096 | 2 vCPU = 2000-4000 connections per worker |
| `gzip_comp_level` | 4 | ARM CPU: compression takes more CPU than bandwidth saves |
| `gzip_buffers` | 32 8k | Increase throughput, utilize available RAM |
| `proxy_buffers` | 8 4k | Sufficient for typical response sizes |
| `ssl_session_cache` | 64m | 12GB available; cache more SSL sessions |

### Monitor Performance Metrics

```bash
# CPU usage per NGINX worker
top -p $(pgrep -d, nginx)

# Memory usage
ps aux | grep nginx | awk '{sum+=$6} END {print "Total NGINX RAM: " sum " KB (" sum/1024 " MB)"}'

# Cache hit ratio over time
awk -F'"' '$4 ~ /X-Cache-Status/ {print $4}' /var/log/nginx/access.log | sort | uniq -c

# Average response time
awk '{print $NF}' /var/log/nginx/access.log | sort -n | awk '{sum+=$1; count++} END {print "Avg response: " sum/count " ms"}'
```

### Optimize Further (If Needed)

**If CPU is high:**
```nginx
gzip_comp_level 3;  # Reduce compression
gzip_disable "text/html";  # Don't compress HTML
```

**If memory is tight:**
```nginx
proxy_buffer_size 2k;
proxy_buffers 4 2k;
gzip_buffers 16 8k;
```

**If cache is full:**
```nginx
proxy_cache_path /var/cache/nginx/plan levels=1:2 keys_zone=plan_cache:50m max_size=250m inactive=1h;
```

---

## Maintenance

### Daily Tasks

```bash
# Check NGINX is running
sudo systemctl status nginx

# Verify no errors in log
sudo tail -5 /var/log/nginx/error.log

# Monitor cache effectiveness
awk '/X-Cache-Status/ {print $(NF-1)}' /var/log/nginx/access.log | sort | uniq -c
```

### Weekly Tasks

```bash
# Rotate old logs if not using logrotate
sudo nginx -s reload

# Check SSL certificate expiration
echo | openssl s_client -servername javasnake.online -connect javasnake.online:443 2>/dev/null | openssl x509 -noout -dates

# Review access patterns
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -10
```

### Monthly Tasks

```bash
# Full config backup
sudo tar -czf /home/ubuntu/nginx-backup-$(date +%Y%m%d).tar.gz /etc/nginx/

# Clear old cache files (older than 30 days)
sudo find /var/cache/nginx/plan -type f -atime +30 -delete

# Review certificate renewal
sudo certbot renew --dry-run --quiet
```

### Annual Tasks

```bash
# Archive logs older than 6 months
sudo find /var/log/nginx -type f -mtime +180 -exec gzip {} \;

# Review and update cipher suites
# Check Mozilla recommendations: https://ssl-config.mozilla.org/
```

---

## Quick Reference Commands

```bash
# Check NGINX status
sudo systemctl status nginx

# Start NGINX
sudo systemctl start nginx

# Stop NGINX
sudo systemctl stop nginx

# Reload NGINX (graceful)
sudo systemctl reload nginx

# Test configuration
sudo nginx -t

# View NGINX version
nginx -v

# Restart with config backup
sudo nginx -s reload && sudo systemctl reload nginx

# View current config
cat /etc/nginx/nginx.conf

# Edit config
sudo nano /etc/nginx/nginx.conf

# Check certificate expiration
certbot certificates

# Manually renew SSL
sudo certbot renew

# View access log
sudo tail -f /var/log/nginx/access.log

# View error log
sudo tail -f /var/log/nginx/error.log

# Check port usage
sudo ss -tlnp | grep nginx

# Test remote connectivity
curl -I https://javasnake.online
```

---

## Emergency Recovery

**If NGINX won't start:**

```bash
# Check what's wrong
sudo nginx -t

# Restore backup
sudo cp /etc/nginx/nginx.conf.backup.$(date +%Y%m%d) /etc/nginx/nginx.conf

# Test again
sudo nginx -t

# Start
sudo systemctl start nginx
```

**If SSL certificate broke:**

```bash
# Check validity
sudo certbot certificates

# Force renewal
sudo certbot renew --force-renewal

# Restart NGINX
sudo systemctl reload nginx
```

**If Plan backend is unreachable:**

```bash
# Test direct connection
curl -I http://localhost:8804

# Check if Plan is running
sudo systemctl status plan  # (or relevant service name)

# Restart Plan
sudo systemctl restart plan

# Verify port is open
sudo ss -tlnp | grep 8804
```

---

## Related Documentation

- **Plan Configuration:** [Plan/config.yml](../config/Plan/config.yml)
- **NGINX Config:** [nginx.conf](../config/nginx.conf)
- **SSL Setup:** [lets_encrypt-free-ssl.md](lets_encrypt-free-ssl.md)
- **Server Info:** [Ubuntu ARM 12GB Setup](../README.md)

---

**Last Updated:** January 12, 2026  
**Tested On:** Ubuntu 22.04 LTS ARM (Oracle Cloud)  
**NGINX Version:** 1.24+  
**Plan Version:** 5.3+
