# Let's Encrypt: Free SSL Certificate Guide

## Overview
Let's Encrypt provides free, automated SSL/TLS certificates for your domain. This guide covers how to obtain and install certificates using Certbot on Ubuntu, and how to integrate them with Nginx.

---

## 1. Prerequisites
- Ubuntu server with sudo/root access
- Domain name (e.g., javasnake.online) pointing to your server's public IP
- Nginx installed and running

---

## 2. Install Certbot
Install Certbot and the Nginx plugin:
```sh
sudo apt update
sudo apt install certbot python3-certbot-nginx
```

---

## 3. Obtain a Certificate
Run Certbot for your domain (replace with your domain):
```sh
sudo certbot --nginx -d javasnake.online
```
- Certbot will automatically configure Nginx for SSL and reload it.
- Follow prompts to enter your email and agree to the terms.

---

## 4. Test SSL
- Visit `https://javasnake.online` in your browser.
- Use [SSL Labs](https://www.ssllabs.com/ssltest/) to check your certificate and configuration.

---

## 5. Automatic Renewal
Let's Encrypt certificates are valid for 90 days. Certbot sets up automatic renewal by default.
Test renewal with:
```sh
sudo certbot renew --dry-run
```

---

## 6. Manual Nginx Configuration (if needed)
If you want to manually configure SSL in your Nginx config, add:
```nginx
server {
	listen 443 ssl;
	server_name javasnake.online;

	ssl_certificate /etc/letsencrypt/live/javasnake.online/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/javasnake.online/privkey.pem;

	# ... your location and proxy settings ...
}
```

---

## 7. Useful Commands
- List certificates: `sudo certbot certificates`
- Renew manually: `sudo certbot renew`
- Revoke: `sudo certbot revoke --cert-path /etc/letsencrypt/live/yourdomain/fullchain.pem`

---

## Links
- [Let's Encrypt](https://letsencrypt.org/)
- [Certbot Documentation](https://certbot.eff.org/)
