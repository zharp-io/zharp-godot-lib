#!/usr/bin/env bash
# GitHub Actions (windows-latest, macos-latest): the e2e game's debug runs (error, crash), then a
# release export (error, crash), against e2e/receiver.py, checked by e2e/check.py.
# Usage: run.sh <export preset: Windows | macOS>
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
E2E=$ROOT/e2e
OUT=$E2E/out
rm -rf "$OUT" "$E2E/game/addons" && mkdir -p "$OUT" && cp -r "$ROOT/addons" "$E2E/game/addons"
echo '{"top":[1,2,3]}' > "$OUT/scores.json"
python "$E2E/receiver.py" "$OUT" 4318 > "$OUT/receiver.log" 2>&1 &
START=$SECONDS
for i in $(seq 1 600); do curl -fsS -o /dev/null http://127.0.0.1:4318/scores.json 2>/dev/null && break; sleep 0.2; done
echo "receiver: $(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:4318/scores.json) after $((SECONDS - START)) s"
rm -f "$OUT/requests.jsonl"
export ZHARP_DEBUG=1
case "$(uname -s)" in
  Darwin) USERDIR="$HOME/Library/Application Support/Godot/app_userdata/Shop Quest" ;;
  *)      USERDIR="$APPDATA/Godot/app_userdata/Shop Quest" ;;
esac
FAILED=0
cd "$E2E/game"
"$GODOT_BIN" --headless --import > "$OUT/import.log" 2>&1

run() { local label=$1 bin=$2 mode=$3; "$bin" --headless --path "$E2E/game" -- --mode=$mode > "$OUT/$label.log" 2>&1; echo "  ran $label: exit $?"; }
release() { local label=$1 bin=$2 mode=$3; "$bin" --headless -- --mode=$mode > "$OUT/$label.log" 2>&1; echo "  ran $label: exit $?"; }
check() {
  touch "$OUT/received.jsonl" "$OUT/requests.jsonl"
  mv "$OUT/received.jsonl" "$OUT/$1.jsonl"; mv "$OUT/requests.jsonl" "$OUT/$1.requests.jsonl"
  if python "$E2E/check.py" "$1" "$OUT/$1.jsonl" "$OUT/$1.requests.jsonl"; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi
}
fresh() { rm -rf "$USERDIR"; }

echo "== Debug runs"
fresh; run error-1 "$GODOT_BIN" error; run error-2 "$GODOT_BIN" error; check error
# Engine frames are whatever the platform's handler prints; the script frames are checked.
export ENGINE_FRAMES=0
fresh; run crash-1 "$GODOT_BIN" crash; run after-1 "$GODOT_BIN" after; run crash-2 "$GODOT_BIN" crash; run after-2 "$GODOT_BIN" after; check crash

echo "== $1 release export"
mkdir -p "$OUT/build"
case "$1" in
  macOS)   "$GODOT_BIN" --headless --export-release macOS "$OUT/build/shop_quest.zip" > "$OUT/export.log" 2>&1
           (cd "$OUT/build" && unzip -q shop_quest.zip); GAME="$OUT/build/Shop Quest.app/Contents/MacOS/Shop Quest" ;;
  Windows) "$GODOT_BIN" --headless --export-release Windows "$OUT/build/shop_quest.exe" > "$OUT/export.log" 2>&1
           GAME="$OUT/build/shop_quest.exe" ;;
esac
[ -e "$GAME" ] || { echo "export failed"; tail -20 "$OUT/export.log"; exit 1; }
fresh; release release-error-1 "$GAME" error; release release-error-2 "$GAME" error; check release-error
fresh; release release-crash-1 "$GAME" crash; release release-after-1 "$GAME" after; release release-crash-2 "$GAME" crash; release release-after-2 "$GAME" after; check release-crash
exit $FAILED
