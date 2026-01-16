#!/bin/bash
# /opt/minecraft/start.sh

cd /opt/minecraft

# java -Xmx8192M -Xms6144M -jar server.jar nogui

java -Xmx8192M -Xms6144M \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=200 \
  -XX:+ParallelRefProcEnabled \
  -XX:+AlwaysPreTouch \
  -XX:G1ReservePercent=20 \
  -XX:SurvivorRatio=32 \
  -XX:MaxTenuringThreshold=1 \
  -XX:+DisableExplicitGC \
  -jar paper-1.21.11-91.jar  nogui