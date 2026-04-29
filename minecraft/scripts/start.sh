#!/usr/bin/env bash
set -euo pipefail
# /opt/minecraft/start.sh
# Version: 1.1.0

SCRIPT_VERSION="1.1.0"
MC_JAR="${MC_JAR:-paper-1.21.11-91.jar}"
MC_DIR="${MC_DIR:-/opt/minecraft}"
MC_MAX_MEM="${MC_MAX_MEM:-8192M}"
MC_MIN_MEM="${MC_MIN_MEM:-6144M}"

if [[ "${1:-}" == "--version" ]]; then
  echo "start.sh $SCRIPT_VERSION"
  exit 0
fi

cd "$MC_DIR"

java -Xmx"$MC_MAX_MEM" -Xms"$MC_MIN_MEM" \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=200 \
  -XX:+ParallelRefProcEnabled \
  -XX:+AlwaysPreTouch \
  -XX:G1ReservePercent=20 \
  -XX:SurvivorRatio=32 \
  -XX:MaxTenuringThreshold=1 \
  -XX:+DisableExplicitGC \
  -jar "$MC_JAR" nogui
