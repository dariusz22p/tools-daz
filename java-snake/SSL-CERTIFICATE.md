


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

Since you only have one domain, use manual DNS validation (no API setup needed):

```
/opt/certbot/bin/certbot certonly --manual --preferred-challenges=dns -d javasnake.com -d *.javasnake.com
```

When prompted:
1. Certbot will show a DNS TXT record to add: `_acme-challenge.javasnake.com` with a specific value
2. Log into GoDaddy DNS settings
3. Add a new TXT record with:
   - Name: `_acme-challenge`
   - Value: (paste the value certbot showed)
   - TTL: 600 (or default)
4. Wait 2-5 minutes for DNS propagation
5. Verify the record with: `nslookup -type=TXT _acme-challenge.javasnake.com` or use https://toolbox.googleapps.com/apps/dig/
6. Return to certbot and press Enter to continue

Note: DNS propagation can take up to 10 minutes. If certbot fails, wait longer and try again.



# end