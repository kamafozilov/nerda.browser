#!/bin/bash
# Builds and opens the app, then rebuilds and reopens it every time a source
# file is saved. A build that fails leaves the running app as it was.
#
#   ./watch.sh
set -uo pipefail
cd "$(dirname "$0")"

state() { find Sources Package.swift -type f -exec stat -f '%N %m' {} + | md5; }

last=""
while true; do
  now="$(state)"
  if [ "$now" != "$last" ]; then
    last="$now"
    echo "— building $(date +%T)"
    if ./build.sh debug >/tmp/nerda-build.log 2>&1; then
      pkill -x Nerda
      while pgrep -x Nerda >/dev/null; do sleep 0.1; done
      # macOS takes a moment to let go of the old one.
      for _ in 1 2 3 4 5 6 7 8 9 10; do open build/Nerda.app 2>/dev/null && break; sleep 0.3; done
      echo "— opened"
    else
      grep -E "error" /tmp/nerda-build.log || tail -20 /tmp/nerda-build.log
    fi
  fi
  sleep 1
done
