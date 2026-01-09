




# Monitor real-time
top -p $(pgrep -f "java.*server.jar")


# check service

sudo journalctl -u minecraft -f

