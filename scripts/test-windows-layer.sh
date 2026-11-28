#!/bin/bash
# Tests the part of Lucid that talks to Windows (Sources/CLucidDesk/windows) without a
# Windows PC: builds it for Windows with MinGW and runs Tests/CLucidDeskTests/windows.c under Wine, on a display
# that only exists in memory.
#
# It checks the pill, the tray icon and its menu, the dictation key, the clipboard, and
# typing into Notepad. With PulseAudio installed it also records from a made-up microphone
# that plays a steady tone, and checks that the tone arrives unbroken.
#
# Needs gcc-mingw-w64-x86-64, wine64 and xvfb. On Ubuntu:
#   sudo apt-get install gcc-mingw-w64-x86-64-win32 wine64 xvfb
#
#   scripts/test-windows-layer.sh           run the checks
#   scripts/test-windows-layer.sh pictures  also keep pictures of the pill, in windows-layer-pictures/
set -euo pipefail
cd "$(dirname "$0")/.."

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "This needs $1. $2" >&2; exit 2; }
}
need x86_64-w64-mingw32-gcc "Install gcc-mingw-w64-x86-64."
need xvfb-run "Install xvfb."
need python3 "Install python3."
WINE=$(command -v wine64 || command -v wine || true)
[ -n "$WINE" ] || { [ -x /usr/lib/wine/wine64 ] && WINE=/usr/lib/wine/wine64; }
[ -n "$WINE" ] || { echo "This needs Wine. Install wine64." >&2; exit 2; }

WORK=$(mktemp -d)
FEEDER=""
PULSE=""
cleanup() {
    [ -n "$FEEDER" ] && kill "$FEEDER" >/dev/null 2>&1 || true
    [ -n "$PULSE" ] && kill "$PULSE" >/dev/null 2>&1 || true
    WINEPREFIX="$WORK/prefix" "${WINE%64}server" -k >/dev/null 2>&1 || true
    case "$WORK" in /tmp/*|/var/*) rm -rf -- "$WORK" ;; esac
}
trap cleanup EXIT

echo "build    the Windows layer and its tests, for Windows"
x86_64-w64-mingw32-gcc -std=c11 -O1 -Wall -Wextra -Wshadow -Wconversion -Wno-sign-conversion -Werror \
    -ISources/CLucidDesk/include Sources/CLucidDesk/windows/*.c Tests/CLucidDeskTests/windows.c -o "$WORK/harness.exe" \
    -luser32 -lgdi32 -lshell32 -lwinmm -lcomdlg32 -ladvapi32 -lversion -lole32 -luuid

export WINEPREFIX="$WORK/prefix" WINEDEBUG=-all
# Wine wants this folder to exist.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

# A microphone that plays a 440 Hz tone, at the speed a real one would. It is a PulseAudio
# of its own, so the sound on this computer is left alone. Something listens to it all the
# while, as a real microphone is always running: otherwise the tone piles up while nobody
# records, and arrives all at once.
if command -v pulseaudio >/dev/null 2>&1; then
    python3 - "$WORK/tone.raw" <<'PY'
import math, struct, sys
rate = 16000
with open(sys.argv[1], "wb") as out:
    out.write(b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * 440 * i / rate))) for i in range(rate * 2)))
PY
    export PULSE_RUNTIME_PATH="$WORK/pulse" PULSE_STATE_PATH="$WORK/pulse-state" PULSE_SERVER="unix:$WORK/pulse.sock"
    mkdir -p "$PULSE_RUNTIME_PATH" "$PULSE_STATE_PATH"
    pulseaudio -n --daemonize=no --use-pid-file=no --exit-idle-time=-1 \
        --load="module-native-protocol-unix socket=$WORK/pulse.sock" \
        --load="module-null-sink sink_name=out" \
        --load="module-pipe-source source_name=mic file=$WORK/mic.fifo format=s16le rate=16000 channels=1" \
        --load="module-loopback source=mic sink=out" \
        >/dev/null 2>&1 &
    PULSE=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -p "$WORK/mic.fifo" ] && break; sleep 0.3; done
    if [ -p "$WORK/mic.fifo" ]; then
        python3 - "$WORK/tone.raw" "$WORK/mic.fifo" >/dev/null 2>&1 <<'PY' &
import sys, time
data = open(sys.argv[1], "rb").read()
out = open(sys.argv[2], "wb", buffering=0)
due = time.monotonic()
while True:
    for offset in range(0, len(data), 320):  # 10 ms at a time
        out.write(data[offset:offset + 320])
        due += 0.01
        now = time.monotonic()
        # After a hold-up, carry on from now. Catching up would play faster than a microphone can.
        if now > due + 0.05:
            due = now
        time.sleep(max(0, due - now))
PY
        FEEDER=$!
        echo "have     a made-up microphone, playing a tone"
    else
        echo "skip     the microphone: PulseAudio did not start"
    fi
else
    echo "skip     the microphone: PulseAudio is not installed"
fi

OUT="$WORK/out"
if [ "${1:-}" = "pictures" ]; then
    OUT="$PWD/windows-layer-pictures"
fi
mkdir -p "$OUT"
echo "run      under Wine"
set +e
xvfb-run -a -s "-screen 0 1280x800x24" "$WINE" "$WORK/harness.exe" "$OUT" 2>&1 | grep -v "^ALSA\|X connection\|^[0-9a-f]*:fixme\|^[0-9a-f]*:err"
CODE=${PIPESTATUS[0]}
set -e

# What was recorded must be the tone that was played: the right pitch, and unbroken.
if [ -f "$OUT/recorded.raw" ]; then
    python3 - "$OUT/recorded.raw" <<'PY' || CODE=1
import struct, sys
data = open(sys.argv[1], "rb").read()
count = len(data) // 2
samples = struct.unpack("<%dh" % count, data[:count * 2])
# The first moments are the made-up microphone getting going.
samples = samples[11200:]
crossings = sum(1 for i in range(1, len(samples)) if (samples[i - 1] < 0) != (samples[i] < 0))
pitch = crossings / 2 / (len(samples) / 16000)
# 400 samples is exactly 11 waves of the tone, so each sample should match the one 400 before.
breaks = sum(1 for i in range(400, len(samples)) if abs(samples[i] - samples[i - 400]) > 600)
good = abs(pitch - 440) < 4 and breaks == 0
print("  %s  the recording is the tone that was played (%.1f Hz, %d breaks)" % ("ok  " if good else "FAIL", pitch, breaks))
sys.exit(0 if good else 1)
PY
fi
[ "${1:-}" = "pictures" ] && echo "The pictures are in $OUT"
exit "$CODE"
