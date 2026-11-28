#!/bin/bash
# The whole Linux app, end to end, on a desktop that only exists in memory. It opens a text
# editor, holds the dictation key, says a sentence into a made-up microphone in a
# synthesised voice, lets go, and checks that the cleaned sentence was typed into the editor.
#
# Run scripts/setup-linux.sh first: this uses the engines and models it installs. Your own
# settings and history are not touched.
#
# Besides what scripts/test-linux-layer.sh needs, this needs espeak-ng, xdotool and curl:
#   sudo apt-get install espeak-ng xdotool curl imagemagick
#
#   scripts/integration-linux.sh            run it
#   scripts/integration-linux.sh pictures   also keep pictures of the screen, in linux-app-pictures/
set -euo pipefail
cd "$(dirname "$0")/.."

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "This needs $1. $2" >&2; exit 2; }
}
need espeak-ng "Install espeak-ng."
need xdotool "Install xdotool."
need curl "Install curl."
need python3 "Install python3."
need pkg-config "Install pkg-config."

BIN=$(swift build -c release --show-bin-path)
[ -x "$BIN/Lucid" ] && [ -x "$BIN/lucid-cli" ] || { echo "Run scripts/setup-linux.sh first: Lucid is not built." >&2; exit 1; }
ENGINES=$("$BIN/lucid-cli" folder engines)
MODELS=$("$BIN/lucid-cli" folder models)

WORK=$(mktemp -d)
trap 'case "$WORK" in /tmp/*|/var/*) rm -rf -- "$WORK" ;; esac' EXIT
OUT="$WORK/out"
if [ "${1:-}" = "pictures" ]; then
  OUT="$PWD/linux-app-pictures"
fi
mkdir -p "$OUT"
# Nothing left from an earlier run may be taken for this one's.
rm -f -- "$OUT/window.txt" "$OUT/editor.txt" "$OUT/app.log"

# The editor that is typed into, and the stand-in for the browser, are the layer's test
# program in two of its guises.
# shellcheck disable=SC2046
${CC:-cc} -std=gnu11 -O1 $(pkg-config --cflags ayatana-appindicator3-0.1 xi xtst) -ISources/CLucidDesk/include \
  Sources/CLucidDesk/linux/*.c Tests/CLucidDeskTests/linux.c -o "$WORK/linux-layer-tests" \
  $(pkg-config --libs ayatana-appindicator3-0.1 xi xtst) -lX11 -lm -lpthread

# What is said, with a pause before and after, as a person would leave.
SAID="Um, so I was thinking we could, uh, meet at two. Actually no, make that three, at the usual place."
espeak-ng -v en-us -s 145 -w "$WORK/said.wav" "$SAID"
python3 - "$WORK/said.wav" "$WORK/said.raw" "$WORK/silence.raw" <<'PY'
import struct, sys, wave
source = wave.open(sys.argv[1])
rate, count, channels = source.getframerate(), source.getnframes(), source.getnchannels()
samples = struct.unpack("<%dh" % (count * channels), source.readframes(count))[::channels]
# To 16 kHz, by straight lines between the samples there are.
wanted = int(count * 16000 / rate)
out = []
for index in range(wanted):
    place = index * rate / 16000
    whole = int(place)
    a, b = samples[whole], samples[min(whole + 1, count - 1)]
    out.append(int(a + (b - a) * (place - whole)))
out = [0] * 6400 + out + [0] * 9600
open(sys.argv[2], "wb").write(struct.pack("<%dh" % len(out), *out))
open(sys.argv[3], "wb").write(b"\0" * 64000)
print(len(out) / 16000)
PY
SECONDS_SAID=$(python3 -c "import os,sys; print(os.path.getsize(sys.argv[1]) / 32000)" "$WORK/said.raw")

cat > "$WORK/inside.sh" <<'INSIDE'
#!/bin/bash
# Runs on the made-up desktop.
set -uo pipefail
say() { echo "$1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }
ok() { echo "  ok    $1"; }
FAILED=0

# Lucid's own folder here, with the real engines and models in it.
mkdir -p "$XDG_DATA_HOME/Lucid"
ln -s "$LUCID_REAL_ENGINES" "$XDG_DATA_HOME/Lucid/engines"
ln -s "$LUCID_REAL_MODELS" "$XDG_DATA_HOME/Lucid/models"
printf '{"models":{"speech":"%s"}}' "$LUCID_SPEECH_MODEL" > "$XDG_DATA_HOME/Lucid/settings.json"

export LUCID_BROWSER="$LUCID_WORK/linux-layer-tests" LUCID_HARNESS_NOTE="$LUCID_OUT/window.txt"
export LUCID_HARNESS_EDITOR="$LUCID_OUT/editor.txt" LUCID_TEST_MADE_UP_KEYS=1
"$LUCID_APP" > "$LUCID_OUT/app.log" 2>&1 &
APP=$!

# The first time it runs, Lucid opens its window: here, the stand-in writes down the address.
for _ in $(seq 150); do [ -s "$LUCID_OUT/window.txt" ] && break; sleep 0.2; done
ADDRESS=$(sed -n 's/.*\[--app=\([^]]*\)\].*/\1/p' "$LUCID_OUT/window.txt" 2>/dev/null)
if [ -z "$ADDRESS" ]; then
  fail "Lucid opens its window when first run"
  kill "$APP" 2>/dev/null; exit 1
fi
ok "Lucid opens its window when first run"
BASE=${ADDRESS%%/#*}
KEY=${ADDRESS##*key=}
state() { curl -s --max-time 5 --noproxy '*' -H "X-Lucid-Key: $KEY" "$BASE/api/state"; }
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {'d': d}))" "$1" 2>/dev/null; }

say "waiting for the engines to load the models"
READY=0
for _ in $(seq 240); do
  if [ "$(state | field "d['status']['state']")" = ready ]; then READY=1; break; fi
  sleep 0.5
done
if [ "$READY" = 1 ]; then ok "the engines start and Home says Lucid is ready"; else
  fail "the engines start and Home says Lucid is ready"
  state | field "[c['title'] + ': ' + c['detail'] for c in d['status']['checks'] if not c['done']]"
fi
[ "$(state | field "d['app']['system']")" = Linux ] && ok "the window says it is on Linux" || fail "the window says it is on Linux"

"$LUCID_WORK/linux-layer-tests" editor &
EDITOR=$!
sleep 2

# Hold the key, speak, let go.
picture() { command -v import >/dev/null 2>&1 && import -window root "$LUCID_OUT/$1.png" 2>/dev/null; }
xdotool keydown Control_R
sleep 0.5
picture key-down
cp "$LUCID_SAID" "$LUCID_TEST_HOME/say.tmp" && mv "$LUCID_TEST_HOME/say.tmp" "$LUCID_TEST_HOME/say.raw"
sleep "$LUCID_SECONDS_SAID"
picture while-speaking
xdotool keyup Control_R
sleep 0.3
picture after-speaking

for _ in $(seq 240); do [ -s "$LUCID_OUT/editor.txt" ] && break; sleep 0.25; done
sleep 0.5
TYPED=$(cat "$LUCID_OUT/editor.txt" 2>/dev/null)
picture typed
say "  said:   $LUCID_WORDS"
say "  typed:  $TYPED"
[ -n "$TYPED" ] && ok "the dictation is typed into the editor" || fail "the dictation is typed into the editor"
echo "$TYPED" | grep -qi "usual place" && ok "it is what was said" || fail "it is what was said"
echo "$TYPED" | grep -qiE "(^|[^a-z])(um|uh)([^a-z]|$)" && fail "the fillers are gone" || ok "the fillers are gone"

HEARD=$(state | field "d['history'][0]['original']")
KEPT=$(state | field "d['history'][0]['text']")
WHERE=$(state | field "d['history'][0]['app']")
say "  heard:  $HEARD"
[ "$KEPT" = "$TYPED" ] && ok "History has the same text" || fail "History has the same text ($KEPT)"
[ -n "$WHERE" ] && [ "$WHERE" != "Unknown app" ] && ok "and says which app it went to ($WHERE)" || fail "and says which app it went to ($WHERE)"

COUNT=$(state | field "len(d['history'])")
[ "$COUNT" = 1 ] && ok "there is one dictation in History" || fail "there is one dictation in History ($COUNT)"

# Escape cancels: nothing is typed, and nothing is added to History.
xdotool keydown Control_R
sleep 0.6
xdotool key Escape
sleep 0.2
xdotool keyup Control_R
sleep 2
NOW=$(cat "$LUCID_OUT/editor.txt" 2>/dev/null)
[ "$NOW" = "$TYPED" ] && [ "$(state | field "len(d['history'])")" = 1 ] && ok "Escape cancels a recording" || fail "Escape cancels a recording (the editor now has: $NOW)"

kill "$EDITOR" 2>/dev/null
kill -TERM "$APP" 2>/dev/null
for _ in $(seq 50); do kill -0 "$APP" 2>/dev/null || break; sleep 0.2; done
kill -0 "$APP" 2>/dev/null && fail "Lucid quits when asked" || ok "Lucid quits when asked"
sleep 0.5
# Only the engines that were started here: there may be a real Lucid running too.
LEFT=$(pgrep -a -x "whisper-server|llama-server" | grep -c "$XDG_DATA_HOME" || true)
if [ "$LEFT" = 0 ]; then ok "and takes its engines with it"; else
  fail "and takes its engines with it"
  pgrep -a -x "whisper-server|llama-server" | grep "$XDG_DATA_HOME" | awk '{print $1}' | xargs -r kill -9
fi
exit "$FAILED"
INSIDE
chmod +x "$WORK/inside.sh"

export LUCID_APP="$BIN/Lucid" LUCID_WORK="$WORK" LUCID_OUT="$OUT" LUCID_REAL_ENGINES="$ENGINES" LUCID_REAL_MODELS="$MODELS"
export LUCID_SAID="$WORK/said.raw" LUCID_SECONDS_SAID="$SECONDS_SAID" LUCID_WORDS="$SAID"
# The speech model that is there: Lucid's usual one, or the one setup was told to get.
LUCID_SPEECH_MODEL=${LUCID_SPEECH_MODEL:-$(cd "$MODELS" && ls ggml-large-v3-turbo-q5_0.bin 2>/dev/null || ls ggml-*.bin 2>/dev/null | awk 'NR == 1')}
export LUCID_SPEECH_MODEL
CODE=0
LUCID_TEST_SOUND="$WORK/silence.raw" scripts/with-test-desktop.sh "$WORK/inside.sh" || CODE=$?
[ "${1:-}" = "pictures" ] && echo "The pictures are in $OUT"
if [ "$CODE" = 0 ]; then echo "PASSED"; else echo "FAILED"; fi
exit "$CODE"
