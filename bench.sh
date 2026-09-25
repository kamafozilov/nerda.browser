#!/bin/bash
# Times Nerda (Bench.swift): launch, opening pages, switching and waking tabs,
# memory, CPU at rest. Built as Nerda Bench, optimized as a release is, with
# data of its own: Nerda and Nerda Dev are left alone. Results go to
# build/bench/<date>/ (JSON, and the logs printed here).
#
#   ./bench.sh        about 8 minutes
#   ./bench.sh web    also Speedometer 3.1, JetStream 3.0 and MotionMark 1.3.1,
#                     about 15 minutes more; run them in Safari too to compare
#
# Leave the Mac alone while it runs, plugged in: a window over Nerda's, or
# something else busy, changes the numbers.
set -euo pipefail
cd "$(dirname "$0")"

APP="$PWD/$(./build.sh bench | tail -1)"
ID=dev.nerda.browser.bench
DATA="$HOME/Library/Application Support/Nerda Bench"
OUT="$PWD/build/bench/$(date +%Y-%m-%d-%H%M)"
LAUNCHES=10
mkdir -p "$OUT"

# Nothing kept from an earlier run: no tabs, history or cache. The compiled
# block list stays (Blocker.swift), as it does between launches for people.
fresh() { rm -rf "$DATA" "$HOME/Library/Caches/$ID" "$HOME/Library/WebKit/$ID/WebsiteData" "$HOME/Library/HTTPStorages/$ID"; }

# Opened as people open it, through LaunchServices: then its WebKit processes
# are counted as its own (Bench.processes).
run() {
  open -n -W --env NERDA_BENCH="$OUT" --env NERDA_BENCH_MODE="$1" \
    --stdout "$OUT/$1.log" --stderr "$OUT/$1.err" "$APP"
  [ "$1" = launch ] || cat "$OUT/$1.log"
}

# Median and slowest of a column of launch.tsv.
summary() { cut -f"$1" "$2" | grep . | sort -n | awk '{ a[NR] = $1 } END { if (NR) printf "median %.0f ms, slowest %.0f ms (%d runs)\n", a[int((NR + 1) / 2)], a[NR], NR }'; }

echo "— pages and tabs"
fresh
run pages

# Leaves the ten sites as its session: launched again with them, as after a restart.
cp "$DATA/session.json" "$OUT/session.json"
for _ in $(seq $LAUNCHES); do cp "$OUT/session.json" "$DATA/session.json"; run launch; done
mv "$OUT/launch.tsv" "$OUT/launch-restore.tsv"

fresh
for _ in $(seq $LAUNCHES); do rm -rf "$DATA"; run launch; done
mv "$OUT/launch.tsv" "$OUT/launch-empty.tsv"

echo
echo "— launch"
echo "  window ready, first run:        $(summary 1 "$OUT/launch-empty.tsv")"
echo "  window ready, with 10 tabs:     $(summary 1 "$OUT/launch-restore.tsv")"
echo "  its page loaded, with 10 tabs:  $(summary 2 "$OUT/launch-restore.tsv")"

if [ "${1:-}" = web ]; then
  echo
  echo "— the web's benchmarks"
  fresh
  run web
fi

echo
echo "$OUT"
