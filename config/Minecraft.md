




# Monitor real-time
top -p $(pgrep -f "java.*server.jar")


# check service
sudo journalctl -u minecraft -f



# Monitor server performance
sudo journalctl -u minecraft -f | grep -i "tps\|ms"


# check ports are open
sudo ss -tlnup | grep java




