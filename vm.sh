#!/bin/bash
# Nerda's test Mac: a macOS VM (Tart) with a screen, mouse and keyboard of its
# own, so trying Nerda by hand never takes the owner's. It shows no window on
# this Mac; to watch it, open the vnc:// address `./vm.sh up` prints in
# Screen Sharing. Each command starts it, or wakes it, first.
#
#   ./vm.sh up            start it; made the first time from Cirrus Labs'
#                         macOS 27 image (a 29 GB download)
#   ./vm.sh open          build Nerda Dev, put it in the VM and open it there
#   ./vm.sh put FILE...   copy files into the VM's home folder
#   ./vm.sh ssh [CMD]     a shell, or a command, in the VM (user admin, sudo
#                         without a password)
#   ./vm.sh do ACTION...  the mouse and screenshots on the VM's screen, in
#                         the screenshot's pixels (vncdotool): `move 400 300
#                         click 1`, `click 3` (right), `pause 1`,
#                         `mousedown 1 drag 600 300 mouseup 1`, `capture a.png`
#   ./vm.sh type TEXT     type text where the cursor is, as it is (pasted, ⌘V)
#   ./vm.sh key KEY...    keys and shortcuts: `cmd-t`, `cmd-shift-t`, `opt-a`,
#                         `esc`, `enter`, `bsp`, `left`
#   ./vm.sh shot [FILE]   a screenshot, to build/vm.png unless named
#   ./vm.sh down          suspend it: its memory is freed, it wakes in seconds
#
# Needs tart (github.com/openai/tart) and vncdo (`uv tool install vncdotool`).
set -euo pipefail
cd "$(dirname "$0")"

VM=nerda
IMAGE=ghcr.io/cirruslabs/macos-golden-gate-vanilla:27.0
RUN=/tmp/nerda-vm
KEY="$HOME/.ssh/nerda-vm"
SSH=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
mkdir -p "$RUN"

# Not `tart list`: it can't read a running VM's disk, and fails.
made() { [ -d "$HOME/.tart/vms/$VM" ]; }
running() { pgrep -qf "tart run $VM "; }
address() { tart ip "$VM" --wait 120; }
vm() { ssh "${SSH[@]}" -o BatchMode=yes "admin@$(address)" "$@"; }
# The address the hypervisor's VNC server printed at boot: vnc://:PASSWORD@127.0.0.1:PORT
vnc() {
  local url
  url="$(grep -o 'vnc://[^ ]*' "$RUN/tart.log" | tail -1)"
  url="${url#vnc://:}"
  PYTHONWARNINGS=ignore vncdo -s "127.0.0.1::${url##*:}" -p "${url%@*}" "$@"
}
# The VM's VNC server takes Alt for ⌘ and Meta for ⌥, and loses a key sent
# together with its modifiers: they go down first, and come up after it.
keys() {
  local args=() key mods mod
  for key in "$@"; do
    mods=""
    [[ $key == ?*-?* ]] && mods="${key%-*}"
    for mod in ${mods//-/ }; do args+=(keydown "$(held "$mod")" pause 0.1); done
    args+=(key "${key##*-}" pause 0.1)
    for mod in ${mods//-/ }; do args+=(keyup "$(held "$mod")"); done
  done
  vnc "${args[@]}"
}
held() { case "$1" in cmd) echo alt ;; opt | option | alt) echo meta ;; *) echo "$1" ;; esac; }

up() {
  if ! made; then
    # Tart picks up a download that broke off, but any other tart command in
    # between throws the part away: so it tries again right here.
    until tart clone "$IMAGE" "$VM"; do sleep 30; done
    tart set "$VM" --cpu 4 --memory 4096 --display 1440x900
  fi
  if ! running; then
    # No window here; the VNC server is the hypervisor's, so its mouse, keys
    # and screenshots need no permission inside the VM. Suspendable, for down.
    nohup tart run "$VM" --no-graphics --vnc-experimental --suspendable >"$RUN/tart.log" 2>&1 &
    until grep -q 'vnc://' "$RUN/tart.log"; do
      kill -0 $! 2>/dev/null || { cat "$RUN/tart.log"; exit 1; }
      sleep 1
    done
  fi
  [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -f "$KEY"
  until nc -z "$(address)" 22 2>/dev/null; do
    running || { cat "$RUN/tart.log"; exit 1; }
    sleep 1
  done
  if ! vm true 2>/dev/null; then
    # A new VM. The image's user is admin, password admin: the key goes in
    # once with it. The image also remembers a 1024x768 screen; forgotten, and
    # started again, the VM comes up at its own 1440x900.
    printf '#!/bin/sh\necho admin\n' >"$RUN/askpass"
    chmod +x "$RUN/askpass"
    SSH_ASKPASS="$RUN/askpass" SSH_ASKPASS_REQUIRE=force ssh "${SSH[@]}" "admin@$(address)" 'mkdir -p .ssh && cat >>.ssh/authorized_keys' <"$KEY.pub"
    vm 'sudo rm -f /Library/Preferences/com.apple.windowserver.displays.plist; sudo shutdown -h now' &>/dev/null || true
    while running; do sleep 1; done
    up
    return
  fi
  grep -o 'vnc://[^ ]*' "$RUN/tart.log" | tail -1
}

case "${1:-}" in
  up) up ;;
  open)
    ./build.sh debug >"$RUN/build.log" 2>&1 || { grep -E "error" "$RUN/build.log" || tail -20 "$RUN/build.log"; exit 1; }
    up >/dev/null
    vm 'pkill -x "Nerda Dev"; while pgrep -x "Nerda Dev" >/dev/null; do sleep 0.1; done; rm -rf "Applications/Nerda Dev.app"; mkdir -p Applications'
    tar -C build -cf - "Nerda Dev.app" | vm 'tar -C Applications -xf - && open "Applications/Nerda Dev.app"'
    ;;
  put) shift; up >/dev/null; scp "${SSH[@]}" -o BatchMode=yes "$@" "admin@$(address):" ;;
  ssh) shift; up >/dev/null; vm "$@" ;;
  do) shift; up >/dev/null; vnc "$@" ;;
  key) shift; up >/dev/null; keys "$@" ;;
  # vncdo's own typing loses Shift (":" comes out ";"): pasted instead.
  type) shift; up >/dev/null; printf %s "$*" | vm pbcopy; keys cmd-v ;;
  shot) up >/dev/null; vnc capture "${2:-build/vm.png}" ;;
  down) tart suspend "$VM"; while running; do sleep 1; done ;;
  *) sed -n '2,/^set/p' "$0" | grep '^#' | cut -c3-; exit 1 ;;
esac
