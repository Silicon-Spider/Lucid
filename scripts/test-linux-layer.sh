#!/bin/bash
# Tests the part of Lucid that talks to a Linux desktop (Sources/CLucidDesk/linux): builds
# Tests/CLucidDeskTests/linux.c and runs it on a desktop that only exists in memory.
#
# It checks the pill, the tray icon and its menu, the dictation key, the clipboard, typing
# into another program's window and into a terminal, and what Lucid does instead in a
# Wayland session. With PulseAudio installed it also records from a made-up microphone that
# plays a steady tone, and checks that the tone arrives unbroken.
#
# Needs what the app is built on, and what scripts/with-test-desktop.sh needs. On Ubuntu:
#   sudo apt-get install libgtk-3-dev libayatana-appindicator3-dev libxi-dev libxtst-dev \
#     xvfb openbox dbus-x11 xcompmgr pulseaudio pulseaudio-utils xterm
#
#   scripts/test-linux-layer.sh           run the checks
#   scripts/test-linux-layer.sh pictures  also keep pictures of the pill, in linux-layer-pictures/
set -euo pipefail
cd "$(dirname "$0")/.."

command -v pkg-config >/dev/null 2>&1 || { echo "This needs pkg-config." >&2; exit 2; }
pkg-config --exists ayatana-appindicator3-0.1 xi xtst \
  || { echo "This needs what the app is built on: see the top of this script." >&2; exit 2; }

WORK=$(mktemp -d)
trap 'case "$WORK" in /tmp/*|/var/*) rm -rf -- "$WORK" ;; esac' EXIT

echo "build    the Linux layer and its tests"
# shellcheck disable=SC2046
${CC:-cc} -std=gnu11 -O1 -Wall -Wextra -Wshadow -Werror \
  $(pkg-config --cflags ayatana-appindicator3-0.1 xi xtst) -ISources/CLucidDesk/include \
  Sources/CLucidDesk/linux/*.c Tests/CLucidDeskTests/linux.c -o "$WORK/linux-layer-tests" \
  $(pkg-config --libs ayatana-appindicator3-0.1 xi xtst) -lX11 -lm -lpthread

OUT="$WORK/out"
if [ "${1:-}" = "pictures" ]; then
  OUT="$PWD/linux-layer-pictures"
fi
mkdir -p "$OUT"
echo "run      on a made-up desktop"
CODE=0
scripts/with-test-desktop.sh "$WORK/linux-layer-tests" "$OUT" || CODE=$?

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
