#!/bin/bash
# Runs a command on a desktop that only exists in memory: a display, a window manager, the
# session's message bus and, where PulseAudio is installed, a microphone that plays a tone.
# Lucid's checks of its Linux app use it, here and in CI.
#
# Nothing of a real desktop is touched: the settings, caches and clipboard are its own.
#
#   scripts/with-test-desktop.sh command [arguments]
#
# LUCID_TEST_SOUND=file plays that file into the microphone instead of the tone. It must be
# 16 kHz, one channel, 16 bits, with no header. While the command runs, a file of the same
# kind moved to $LUCID_TEST_HOME/say.raw is played once, straight away: that is how a test
# speaks into the microphone at a moment of its choosing.
#
# Needs xvfb, openbox and dbus. On Ubuntu:
#   sudo apt-get install xvfb openbox dbus-x11 xcompmgr pulseaudio pulseaudio-utils
set -euo pipefail

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "This needs $1. $2" >&2; exit 2; }
}
need xvfb-run "Install xvfb."
need openbox "Install openbox."
need dbus-run-session "Install dbus."
need python3 "Install python3."
[ $# -gt 0 ] || { echo "usage: scripts/with-test-desktop.sh command [arguments]" >&2; exit 2; }

HOME_OF_TEST=$(mktemp -d /tmp/lucid-desktop.XXXXXX)
trap 'case "$HOME_OF_TEST" in /tmp/lucid-desktop.*) rm -rf -- "$HOME_OF_TEST" ;; esac' EXIT
export XDG_RUNTIME_DIR="$HOME_OF_TEST/run" XDG_CACHE_HOME="$HOME_OF_TEST/cache" XDG_CONFIG_HOME="$HOME_OF_TEST/config"
export XDG_DATA_HOME="${LUCID_TEST_DATA:-$HOME_OF_TEST/data}"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
chmod 700 "$XDG_RUNTIME_DIR"
# This display is X11, whatever the desktop this is run from.
export XDG_SESSION_TYPE=x11
unset WAYLAND_DISPLAY
# There is nothing here for screen readers to talk to, and GTK complains of it otherwise.
export NO_AT_BRIDGE=1

SOUND="${LUCID_TEST_SOUND:-}"
if [ -z "$SOUND" ]; then
  SOUND="$HOME_OF_TEST/tone.raw"
  python3 - "$SOUND" <<'PY'
import math, struct, sys
rate = 16000
with open(sys.argv[1], "wb") as out:
    out.write(b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * 440 * i / rate))) for i in range(rate * 2)))
PY
fi
cat > "$HOME_OF_TEST/feed.py" <<'PY'
# Plays a file into the made-up microphone, over and over, at the speed a real one would.
# A file that appears as say.raw beside this one is played once, at once.
import os, sys, time
usual = open(sys.argv[1], "rb").read()
out = open(sys.argv[2], "wb", buffering=0)
say = os.path.join(os.path.dirname(os.path.abspath(__file__)), "say.raw")
due = time.monotonic()
data, offset = usual, 0
while True:
    if data is usual and os.path.exists(say):
        try:
            data, offset = open(say, "rb").read(), 0
            os.remove(say)
        except OSError:
            data = usual
    out.write(data[offset:offset + 320])  # 10 ms at a time
    offset += 320
    if offset >= len(data):
        data, offset = usual, 0
    due += 0.01
    now = time.monotonic()
    # After a hold-up, carry on from now. Catching up would play faster than a microphone can.
    if now > due + 0.05:
        due = now
    time.sleep(max(0, due - now))
PY

export LUCID_TEST_HOME="$HOME_OF_TEST" LUCID_TEST_SOUND_FILE="$SOUND"
set +e
dbus-run-session -- xvfb-run -a -s "-screen 0 1280x800x24" bash -c '
  openbox >/dev/null 2>&1 &
  # Something that blends windows, so the pill can be see-through, as on a real desktop.
  command -v xcompmgr >/dev/null 2>&1 && { xcompmgr >/dev/null 2>&1 & }
  PULSE=; FEED=
  if command -v pulseaudio >/dev/null 2>&1; then
    # A sound system of its own, so the sound on this computer is left alone. Something
    # listens to the microphone all the while, as a real one is always running: otherwise
    # the sound piles up while nobody records, and arrives all at once.
    export PULSE_RUNTIME_PATH="$LUCID_TEST_HOME/pulse" PULSE_STATE_PATH="$LUCID_TEST_HOME/pulse-state" PULSE_SERVER="unix:$LUCID_TEST_HOME/pulse.sock"
    mkdir -p "$PULSE_RUNTIME_PATH" "$PULSE_STATE_PATH"
    pulseaudio -n --daemonize=no --use-pid-file=no --exit-idle-time=-1 \
      --load="module-native-protocol-unix socket=$LUCID_TEST_HOME/pulse.sock" \
      --load="module-null-sink sink_name=out" \
      --load="module-pipe-source source_name=mic file=$LUCID_TEST_HOME/mic.fifo format=s16le rate=16000 channels=1" \
      --load="module-loopback source=mic sink=out" >/dev/null 2>&1 &
    PULSE=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -p "$LUCID_TEST_HOME/mic.fifo" ] && break; sleep 0.3; done
    if [ -p "$LUCID_TEST_HOME/mic.fifo" ]; then
      python3 "$LUCID_TEST_HOME/feed.py" "$LUCID_TEST_SOUND_FILE" "$LUCID_TEST_HOME/mic.fifo" >/dev/null 2>&1 &
      FEED=$!
    fi
  fi
  sleep 0.7
  "$@"
  CODE=$?
  [ -n "$FEED" ] && kill "$FEED" >/dev/null 2>&1
  [ -n "$PULSE" ] && kill "$PULSE" >/dev/null 2>&1
  exit $CODE
' with-test-desktop "$@"
CODE=$?
set -e
exit "$CODE"
