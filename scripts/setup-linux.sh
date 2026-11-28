#!/bin/bash
# Sets Lucid up on Linux: installs the speech and cleanup engines, downloads the models,
# builds the app, and adds it to the applications menu, so it opens like any other app.
# Safe to run again: what is already there is skipped, and model downloads continue.
#
#   scripts/setup-linux.sh                                   the engines and Lucid's two models (about 1 GB)
#   scripts/setup-linux.sh --with-general                    also Qwen 3.5 4B (2.6 GB), for the Medium level
#   scripts/setup-linux.sh --speech-model ggml-base.en.bin   a smaller, faster speech model instead
#   scripts/setup-linux.sh --build-llama                     build llama.cpp here instead of downloading it
#   scripts/setup-linux.sh --no-app                          only what lucid-cli needs, without the app
#   scripts/setup-linux.sh --allow-keys                      for a Wayland session: see below
set -euo pipefail
cd "$(dirname "$0")/.."

WITH_GENERAL=0
SPEECH_MODEL=ggml-large-v3-turbo-q5_0.bin
BUILD_LLAMA=0
APP=1
ALLOW_KEYS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --with-general) WITH_GENERAL=1 ;;
    --speech-model) SPEECH_MODEL=${2:?--speech-model needs the name of a model file}; shift ;;
    --build-llama) BUILD_LLAMA=1 ;;
    --no-app) APP=0 ;;
    --allow-keys) ALLOW_KEYS=1 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# A Wayland session does not show apps the keys pressed in other apps, and does not let one
# app press keys in another. Lucid can still do both through the keyboards themselves, if
# the person signed in at this computer is allowed to read them and to make one.
if [ "$ALLOW_KEYS" = 1 ]; then
  echo "This lets programs that you run read every key you type and press keys, as any"
  echo "program can in an X11 session. It is what lets Lucid see its dictation key and paste"
  echo "in a Wayland session. It writes /etc/udev/rules.d/70-lucid.rules, which you can"
  echo "delete to undo it. Your password is asked for, to write there."
  sudo sh -c 'cat > /etc/udev/rules.d/70-lucid.rules' <<'RULES'
# Lets the person signed in at this computer use Lucid in a Wayland session: read the
# keyboards, to see the dictation key, and make a keyboard of its own, to paste.
KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"
SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_KEYBOARD}=="1", TAG+="uaccess"
RULES
  sudo udevadm control --reload
  sudo udevadm trigger --subsystem-match=input --subsystem-match=misc
  echo "Done. Sign out and in again, then open Lucid."
  exit 0
fi

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "$1 is required. $2" >&2; exit 1; }
}
need swift "Install it from https://www.swift.org/install/linux and run this again."
need git "Install git and run this again."
need curl "Install curl and run this again."
need tar "Install tar and run this again."

# The app is built on GTK. Without what is needed to build on it, only lucid-cli can be made.
if [ "$APP" = 1 ]; then
  MISSING=0
  for header in /usr/include/gtk-3.0/gtk/gtk.h \
      /usr/include/X11/extensions/XInput2.h /usr/include/X11/extensions/XTest.h; do
    [ -f "$header" ] || MISSING=1
  done
  if [ "$MISSING" = 1 ]; then
    echo "The app is built on GTK, and what is needed to build on it is not installed. Install it with:" >&2
    if command -v apt-get >/dev/null 2>&1; then
      echo "  sudo apt-get install libgtk-3-dev libxi-dev libxtst-dev libayatana-appindicator3-1" >&2
    elif command -v dnf >/dev/null 2>&1; then
      echo "  sudo dnf install gtk3-devel libXi-devel libXtst-devel libayatana-appindicator-gtk3" >&2
    elif command -v pacman >/dev/null 2>&1; then
      echo "  sudo pacman -S gtk3 libayatana-appindicator libxi libxtst" >&2
    else
      echo "  the development packages of GTK 3, Xi and Xtst" >&2
    fi
    echo "Then run this again. Or run it with --no-app, for lucid-cli alone." >&2
    exit 1
  fi
fi

echo "build    lucid-cli"
swift build -c release --product lucid-cli
CLI="$(swift build -c release --show-bin-path)/lucid-cli"
ENGINES=$("$CLI" folder engines)
MODELS=$("$CLI" folder models)
[ -n "$ENGINES" ] && [ -n "$MODELS" ] || { echo "lucid-cli did not say where its folders are." >&2; exit 1; }

WORK=$(mktemp -d)
trap 'case "$WORK" in /tmp/*|/var/*) rm -rf -- "$WORK" ;; esac' EXIT
JOBS=$(nproc 2>/dev/null || echo 2)

# Builds one of an engine's programs from its source, and puts it in a folder of its own.
# Each is built to stand alone, so there is nothing else of the engine's to keep.
build_engine() {
  local program=$1 repository=$2 tag=$3; shift 3
  need cmake "It is needed to build $program. Install cmake and a C++ compiler, and run this again."
  command -v c++ >/dev/null 2>&1 || command -v g++ >/dev/null 2>&1 || command -v clang++ >/dev/null 2>&1 \
    || { echo "A C++ compiler is required to build $program. Install g++ and run this again." >&2; exit 1; }
  echo "build    $program from $repository $tag (a few minutes)"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "https://github.com/$repository" "$WORK/$program-source"
  cmake -S "$WORK/$program-source" -B "$WORK/$program-build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF "$@" >"$WORK/$program.log" 2>&1 \
    && cmake --build "$WORK/$program-build" --target "$program" -j "$JOBS" >>"$WORK/$program.log" 2>&1 \
    || { tail -30 "$WORK/$program.log" >&2; echo "$program did not build. The last of what the build said is above." >&2; exit 1; }
  mkdir -p "$ENGINES/$program"
  cp "$WORK/$program-build/bin/$program" "$ENGINES/$program/$program"
}

# The newest few of a project's releases, by the names it gives them. Every stage reads
# all it is given: one that stopped early would stop the script.
newest_tags() {
  git ls-remote --tags --refs "https://github.com/$1" | sed 's|.*refs/tags/||' | grep -E "$2" | sort -V -r | awk -v most="$3" 'NR <= most'
}

if [ -x "$ENGINES/whisper-server/whisper-server" ]; then
  echo "have     whisper-server"
else
  # whisper.cpp offers nothing ready-made for Linux, so it is built here.
  TAG=$(newest_tags ggml-org/whisper.cpp '^v[0-9]+\.[0-9]+\.[0-9]+$' 1)
  [ -n "$TAG" ] || { echo "Could not find a release of whisper.cpp." >&2; exit 1; }
  build_engine whisper-server ggml-org/whisper.cpp "$TAG" -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_SDL2=OFF
fi

if [ -x "$ENGINES/llama-server/llama-server" ]; then
  echo "have     llama-server"
else
  case "$(uname -m)" in
    x86_64) ARCH=x64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) ARCH=; BUILD_LLAMA=1 ;;
  esac
  TAGS=$(newest_tags ggml-org/llama.cpp '^b[0-9]+$' 4)
  [ -n "$TAGS" ] || { echo "Could not find a release of llama.cpp." >&2; exit 1; }
  if [ "$BUILD_LLAMA" = 0 ]; then
    # The plain build, which runs on any processor. The newest release may still be on its
    # way up, so the few before it are tried too.
    for TAG in $TAGS; do
      FILE="llama-$TAG-bin-ubuntu-$ARCH.tar.gz"
      if curl -fsSL -o "$WORK/$FILE" "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/$FILE"; then
        echo "download $FILE ($(( $(stat -c %s "$WORK/$FILE") / 1048576 )) MB)"
        mkdir -p "$WORK/llama"
        tar -xzf "$WORK/$FILE" -C "$WORK/llama"
        FOUND=$(find "$WORK/llama" -type f -name llama-server | awk 'NR == 1')
        if [ -n "$FOUND" ]; then
          # It comes with libraries it needs beside it, so the whole folder is kept.
          mkdir -p "$ENGINES/llama-server"
          cp -a "$(dirname "$FOUND")/." "$ENGINES/llama-server/"
          # Made for Ubuntu. On another system it may not start, and is built here instead.
          if "$ENGINES/llama-server/llama-server" --version >/dev/null 2>&1; then
            break
          fi
          echo "         it does not run on this system"
          rm -rf -- "$ENGINES/llama-server"
        fi
        break
      fi
    done
  fi
  if [ ! -x "$ENGINES/llama-server/llama-server" ]; then
    build_engine llama-server ggml-org/llama.cpp "$(echo "$TAGS" | awk 'NR == 1')" -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON -DLLAMA_CURL=OFF
  fi
fi

get_model() {
  if [ -f "$MODELS/$2" ]; then
    echo "have     $2"
  else
    echo "download $2"
    "$CLI" download "$1" "$2" || { echo "Could not download $2. Run this script again to continue it." >&2; exit 1; }
  fi
}
get_model ggerganov/whisper.cpp "$SPEECH_MODEL"
get_model superwhisper/s1-mini-GGUF s1-mini-q4_k_m.gguf
[ "$WITH_GENERAL" = 1 ] && get_model unsloth/Qwen3.5-4B-GGUF Qwen3.5-4B-Q4_K_M.gguf

echo
"$CLI" doctor --speech-model "$SPEECH_MODEL" || { echo "Setup did not finish. See what is missing above." >&2; exit 1; }

if [ "$APP" = 1 ]; then
  echo
  echo "build    Lucid"
  swift build -c release --product Lucid
  APP_PATH="$(swift build -c release --show-bin-path)/Lucid"
  # An entry in the applications menu, with Lucid's icon, so it opens without a terminal.
  "$APP_PATH" --install-launcher || echo "Could not add Lucid to the applications menu." >&2

  echo
  echo "Lucid is ready. Open it from your applications menu, or run:"
  echo "  $APP_PATH"
  echo "It sits in the panel. Hold Right Ctrl and speak, then let go."
  if [ "${XDG_SESSION_TYPE:-}" = wayland ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    echo
    echo "This is a Wayland session, which keeps the dictation key from Lucid and does not let"
    echo "it paste. To allow both, run:  scripts/setup-linux.sh --allow-keys"
    echo "Without that, sign in with an X11 (\"Xorg\") session, where neither is needed."
  fi
fi
