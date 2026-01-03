


https://certbot.eff.org/instructions?ws=nginx&os=pip&tab=wildcard


```
# Check available Python versions (Python 3.9+ recommended)
python3.9 --version  # or python3.10, python3.11

# Remove old venv if upgrading
sudo rm -rf /opt/certbot/

# Create venv with newer Python version (use python3.9+ if available)
sudo python3.9 -m venv /opt/certbot/
sudo /opt/certbot/bin/pip install --upgrade pip
sudo /opt/certbot/bin/pip install certbot certbot-nginx
sudo ln -s /opt/certbot/bin/certbot /usr/bin/certbot
sudo /opt/certbot/bin/pip install certbot-dns-godaddy

# Fix OpenSSL 1.0.2k incompatibility (CentOS 7 has old OpenSSL)
# urllib3 v2 requires OpenSSL 1.1.1+, so downgrade to v1.26
sudo /opt/certbot/bin/pip install 'urllib3<2'
```

# Set up automatic renewal
We recommend running the following line, which will add a cron job to the default crontab.

```
echo "0 0,12 * * * root /opt/certbot/bin/python -c 'import random; import time; time.sleep(random.random() * 3600)' && sudo certbot renew -q" | sudo tee -a /etc/crontab > /dev/null
```

# setup wildcard

First, create GoDaddy API credentials file on remote server:

```
mkdir -p /root/.secrets/certbot
vim /root/.secrets/certbot/godaddy.ini
```

Add your GoDaddy API credentials:
```
dns_godaddy_key = YOUR_GODADDY_API_KEY
dns_godaddy_secret = YOUR_GODADDY_API_SECRET
```

**Important:** Your GoDaddy API key must have DNS/Domain permissions enabled. If you get a 403 Forbidden error:
1. Log into GoDaddy account
2. Go to Account Settings > Developer (or API Keys)
3. Create/regenerate API key with "DNS" and "Domains" permissions
4. Update the credentials file with the new key and secret
5. Ensure the API key is for the account that owns javasnake.com domain

Set proper permissions:
```
chmod 600 /root/.secrets/certbot/godaddy.ini
```

Then run certbot with full authenticator syntax:
```
/opt/certbot/bin/certbot certonly --authenticator dns-godaddy --dns-godaddy-credentials /root/.secrets/certbot/godaddy.ini -d javasnake.com -d *.javasnake.com
```



# end