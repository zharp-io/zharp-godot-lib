#!/usr/bin/env bash
# End-to-end checks in the zharp-godot-test image (e2e/docker/Dockerfile), against a stand-in
# receiver (e2e/receiver.py) — never a real Zharp:
#
#   docker build -t zharp-godot-test:4.5.1 e2e/docker
#   docker run --rm -v "$PWD:/src:ro" zharp-godot-test:4.5.1 bash /src/e2e/run.sh
#
# Each scenario runs twice: a GDScript error, logs, a hang, an engine crash (OS.crash), sending
# while offline; then the same game as a Linux release export (scripts as compiled tokens), and
# the web export in headless Chromium.
set -uo pipefail
SRC=${SRC:-/src}
W=/w
rm -rf $W && mkdir -p $W && cp -r $SRC/e2e/. $W/ && cp -r $SRC/addons $W/game/addons
OUT=$W/out
mkdir -p $OUT && echo '{"top":[1,2,3]}' > $OUT/scores.json
python3 $W/receiver.py $OUT 4318 > $W/receiver.log 2>&1 &
USERDIR="$HOME/.local/share/godot/app_userdata/Shop Quest"
FAILED=0

cd $W/game
timeout 120 godot --headless --import > $W/import.log 2>&1 || { echo "import failed"; tail -20 $W/import.log; exit 1; }

# run <label> <binary> <mode> [env...]: one launch of the game.
run() {
  local label=$1 bin=$2 mode=$3; shift 3
  env "$@" timeout 60 $bin --headless -- --mode=$mode > $W/$label.log 2>&1
  echo "  ran $label ($mode): exit $?"
}

# scenario <name>: what the receiver got since the last one, checked by check.py.
check() {
  local name=$1
  touch $OUT/received.jsonl $OUT/requests.jsonl
  mv $OUT/received.jsonl $OUT/$name.jsonl
  mv $OUT/requests.jsonl $OUT/$name.requests.jsonl
  if python3 $W/check.py $name $OUT/$name.jsonl $OUT/$name.requests.jsonl; then echo "PASS $name"; else echo "FAIL $name"; FAILED=1; fi
}

fresh() { rm -rf "$USERDIR"; }

echo "== Debug runs (the editor binary)"
fresh
run error-1 godot error; run error-2 godot error; check error
fresh
run logs-off godot logs; run logs-on godot logs ZHARP_LOGS=true; check logs
fresh
run hang-1 godot hang; run hang-2 godot hang; check hang
fresh
run crash-1 godot crash; run after-1 godot after; run crash-2 godot crash; run after-2 godot after; check crash
fresh
run offline-1 godot error ZHARP_ENDPOINT=http://127.0.0.1:9; run offline-2 godot hang ZHARP_ENDPOINT=http://127.0.0.1:9
check offline-nothing
run online godot after; check offline

echo "== Linux release export"
mkdir -p $W/build/linux
timeout 300 godot --headless --export-release Linux $W/build/linux/shop_quest.x86_64 > $W/export-linux.log 2>&1 || { echo "export failed"; tail -20 $W/export-linux.log; FAILED=1; }
GAME=$W/build/linux/shop_quest.x86_64
fresh
run release-error-1 $GAME error; run release-error-2 $GAME error; check release-error
fresh
run release-crash-1 $GAME crash; run release-after-1 $GAME after; run release-crash-2 $GAME crash; run release-after-2 $GAME after; check release-crash

echo "== Web export (headless Chromium)"
mkdir -p $OUT/web
if timeout 300 godot --headless --export-release Web $OUT/web/index.html > $W/export-web.log 2>&1; then
  # The page runs the error scenario, sends, and stays open; Chromium is stopped after 45 s.
  chromium --headless=new --no-sandbox --use-angle=swiftshader --enable-unsafe-swiftshader     --enable-logging=stderr --v=1 --remote-debugging-port=9222     "http://localhost:4318/web/index.html" > $W/web.log 2>&1 &
  CHROME=$!; sleep 45; kill $CHROME; wait $CHROME 2>/dev/null
  grep -a "INFO:CONSOLE" $W/web.log | grep -a "web/index.js" | sed 's/^.*CONSOLE:[0-9]*\] //' > $W/web-console.log
  echo "  ran web: $(wc -l < $W/web-console.log) console lines"
  check web
else
  echo "web export failed"; tail -20 $W/export-web.log; FAILED=1
fi

# Mount a folder at /results to keep what was received (the backend's fixtures come from it).
[ -d /results ] && cp $OUT/*.jsonl $W/*.log /results/ 2>/dev/null
exit $FAILED
