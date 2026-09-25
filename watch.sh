#!/bin/bash
# Builds and opens Nerda Dev, then rebuilds and reopens it every time a source
# file is saved. It opens behind the window in use, which keeps the keyboard,
# and never while it is the app in use: the new build waits until you switch
# to something else, and your tabs come back in it. A build that fails leaves
# the running app as it was. The released Nerda, if it is open, is left alone.
#
#   ./watch.sh         on every save
#   ./watch.sh once    build now; it goes in when it can, in the background
set -uo pipefail
cd "$(dirname "$0")"

state() { find Sources Package.swift -type f -exec stat -f '%N %m' {} + | md5; }

build() {
  echo "— building $(date +%T)"
  ./build.sh debug >/tmp/nerda-build.log 2>&1 && return
  grep -E "error" /tmp/nerda-build.log || tail -20 /tmp/nerda-build.log
  return 1
}

reopen() {
  while lsappinfo info -only bundleid "$(lsappinfo front)" | grep -q '"dev.nerda.browser.debug"'; do sleep 1; done
  pkill -x "Nerda Dev"
  while pgrep -x "Nerda Dev" >/dev/null; do sleep 0.1; done
  # macOS takes a moment to let go of the old one.
  for _ in 1 2 3 4 5 6 7 8 9 10; do open -g "build/Nerda Dev.app" 2>/dev/null && break; sleep 0.3; done
  echo "— opened"
}

case "${1:-}" in
  once)
    build || exit 1
    nohup "$0" reopen >/dev/null 2>&1 &
    ;;
  reopen) reopen ;;
  *)
    last=""
    while true; do
      now="$(state)"
      if [ "$now" != "$last" ]; then
        last="$now"
        build && reopen
      fi
      sleep 1
    done
    ;;
esac
