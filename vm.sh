#!/bin/bash
# Nerda's test Mac: a macOS VM (Tart) with a screen, mouse and keyboard of its
# own, so trying Nerda by hand never takes the owner's. It shows no window on
# this Mac; to watch it, open the vnc:// address `./vm.sh up` prints in
# Screen Sharing. Each command starts it, or wakes it, first.
#
# One VM, one agent at a time: a command waits while another checkout has
# it, which it keeps until 3 minutes after its last command (or `done`).
# 5 minutes after anyone's last command it suspends itself, freeing its memory.
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
#   ./vm.sh done          let the other agents have it (it suspends on its own)
#   ./vm.sh down          suspend it now: its memory is freed, it wakes in seconds
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
# Who has the VM: this checkout, as each agent works in its own.
ME="$PWD"
# The holder keeps it this long after its last command: time to read a
# screenshot, change the code and build again, not to hold up the others.
LEASE=180
# With no command from anyone for this long, it is suspended.
IDLE=300

# Seconds since a file last changed; for none, since forever.
age() { echo $(( $(date +%s) - $(stat -f %m "$1" 2>/dev/null || echo 0) )); }
# Runs a command as the only vm.sh changing the files below.
locked() {
  local status
  until mkdir "$RUN/lock" 2>/dev/null; do
    # Left behind by a vm.sh ended inside (a suspend takes seconds, not minutes).
    if [ "$(age "$RUN/lock")" -gt 120 ]; then rmdir "$RUN/lock" 2>/dev/null || true; fi
    sleep 0.2
  done
  "$@" && status=0 || status=$?
  rmdir "$RUN/lock"
  return $status
}
holder() { cat "$RUN/lease" 2>/dev/null || true; }
take() {
  local held
  held="$(holder)"
  [ -z "$held" ] || [ "$held" = "$ME" ] || [ "$(age "$RUN/lease")" -ge "$LEASE" ] || return 1
  printf '%s\n' "$ME" >"$RUN/lease"
  touch "$RUN/used"
}
keep() { if [ "$(holder)" = "$ME" ]; then touch "$RUN/lease" "$RUN/used"; fi; }
release() { if [ "$(holder)" = "$ME" ]; then rm -f "$RUN/lease"; fi; }
# Waits for the VM, then keeps it while this command runs, however long.
claim() {
  local waiting=""
  until locked take; do
    if [ -z "$waiting" ]; then
      waiting=1
      echo "The VM is in use by $(basename "$(holder)"); waiting (up to ${LEASE}s after its last command)..." >&2
    fi
    sleep 2
  done
  [ -z "$waiting" ] || echo "Got the VM." >&2
  ( while sleep 30; do locked keep; done ) >/dev/null 2>&1 &
  keeper=$!
  # Ended quietly: no "Terminated" when the command is done.
  disown $keeper
  trap 'kill $keeper 2>/dev/null; locked keep' EXIT
}
# What another checkout put in (./vm.sh open) isn't this one's build.
whose_app() {
  local owner
  owner="$(cat "$RUN/app" 2>/dev/null || true)"
  if [ -n "$owner" ] && [ "$owner" != "$ME" ]; then
    echo "Note: Nerda Dev in the VM is $(basename "$owner")'s build; ./vm.sh open puts in this one's." >&2
  fi
}
# Out of this command's process group: tart and the idle watch outlive it.
# Run only in the background (&): exec makes that job the process itself.
detach() { exec perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "$!\n"' "$@" </dev/null; }
# Suspends the VM once no one has used it for IDLE seconds.
watch_idle() {
  while running; do
    sleep 15
    if locked idle_suspend; then break; fi
  done
}
idle_suspend() {
  [ "$(age "$RUN/used")" -ge "$IDLE" ] || return 1
  tart suspend "$VM" >/dev/null 2>&1 || true
  while running; do sleep 1; done
  rm -f "$RUN/lease"
}
suspend() {
  tart suspend "$VM"
  while running; do sleep 1; done
  rm -f "$RUN/lease"
}

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
    detach tart run "$VM" --no-graphics --vnc-experimental --suspendable >"$RUN/tart.log" 2>&1 &
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
  # Not `kill -0 0`, which is true: 0 is this process's own group.
  if ! { [ -s "$RUN/watch.pid" ] && kill -0 "$(cat "$RUN/watch.pid")" 2>/dev/null; }; then
    detach "$PWD/vm.sh" watch >/dev/null 2>&1 &
  fi
  grep -o 'vnc://[^ ]*' "$RUN/tart.log" | tail -1
}

case "${1:-}" in
  up) claim; up ;;
  open)
    ./build.sh debug >"$RUN/build.log" 2>&1 || { grep -E "error" "$RUN/build.log" || tail -20 "$RUN/build.log"; exit 1; }
    claim
    up >/dev/null
    vm 'pkill -x "Nerda Dev"; while pgrep -x "Nerda Dev" >/dev/null; do sleep 0.1; done; rm -rf "Applications/Nerda Dev.app"; mkdir -p Applications'
    tar -C build -cf - "Nerda Dev.app" | vm 'tar -C Applications -xf - && open "Applications/Nerda Dev.app"'
    printf '%s\n' "$ME" >"$RUN/app"
    ;;
  put) shift; claim; up >/dev/null; scp "${SSH[@]}" -o BatchMode=yes "$@" "admin@$(address):" ;;
  ssh) shift; claim; up >/dev/null; vm "$@" ;;
  do) shift; claim; whose_app; up >/dev/null; vnc "$@" ;;
  key) shift; claim; whose_app; up >/dev/null; keys "$@" ;;
  # vncdo's own typing loses Shift (":" comes out ";"): pasted instead.
  type) shift; claim; whose_app; up >/dev/null; printf %s "$*" | vm pbcopy; keys cmd-v ;;
  shot) claim; whose_app; up >/dev/null; vnc capture "${2:-build/vm.png}" ;;
  done) locked release ;;
  down) claim; if running; then locked suspend; fi ;;
  watch) echo $$ >"$RUN/watch.pid"; watch_idle ;;
  *) sed -n '2,/^set/p' "$0" | grep '^#' | cut -c3-; exit 1 ;;
esac
