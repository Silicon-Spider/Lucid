#!/bin/bash
# Makes the Mac download: Lucid.app with its engines inside, so that whoever downloads it
# needs neither Homebrew nor a terminal.
#
#   dist/Lucid-<version>-mac-arm64.zip    unpack it and move Lucid to Applications
#
# The models are not inside: Lucid downloads them itself, from its window, the first time.
#
# The app is signed ad hoc, not with a certificate from Apple, so macOS asks whoever opens
# it to confirm in System Settings that they mean to.
#
# Needs Xcode's command line tools, cmake, git and curl.
# LUCID_ENGINE_CACHE=folder keeps the engines there between runs. Building one takes minutes.
set -euo pipefail
cd "$(dirname "$0")/.."

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "$1 is required. $2" >&2; exit 1; }
}
need swift "xcode-select --install provides it."
need cmake "brew install cmake provides it."
need git "xcode-select --install provides it."
need curl ""
[ "$(uname -m)" = arm64 ] || { echo "Lucid's Mac download is made on, and for, Apple Silicon." >&2; exit 1; }

VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/LucidApp/Desk.swift)
[ -n "$VERSION" ] || { echo "Could not read Lucid's version from Sources/LucidApp/Desk.swift." >&2; exit 1; }

WORK=$(mktemp -d)
trap 'case "$WORK" in /tmp/*|/var/*|/private/*) rm -rf -- "$WORK" ;; esac' EXIT
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
CACHE="${LUCID_ENGINE_CACHE:-$WORK/cache}"
mkdir -p "$CACHE"

# The newest few of a project's releases, by the names it gives them. Every stage reads
# all it is given: one that stopped early would stop the script.
newest_tags() {
  git ls-remote --tags --refs "https://github.com/$1" | sed 's|.*refs/tags/||' | grep -E "$2" | sort -V -r | awk -v most="$3" 'NR <= most'
}

# ---- The speech engine, built here: whisper.cpp offers no ready-made program for a Mac.
# Built for every Apple Silicon Mac, not only this one, with its graphics code inside it.
WHISPER_TAG=$(newest_tags ggml-org/whisper.cpp '^v[0-9]+\.[0-9]+\.[0-9]+$' 1)
[ -n "$WHISPER_TAG" ] || { echo "Could not find a release of whisper.cpp." >&2; exit 1; }
WHISPER="$CACHE/whisper-server-$WHISPER_TAG"
if [ -x "$WHISPER/whisper-server" ]; then
  echo "have     whisper-server $WHISPER_TAG"
else
  echo "build    whisper-server from whisper.cpp $WHISPER_TAG (a few minutes)"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$WORK/whisper-source"
  cmake -S "$WORK/whisper-source" -B "$WORK/whisper-build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
      -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_SDL2=OFF >"$WORK/whisper.log" 2>&1 \
    && cmake --build "$WORK/whisper-build" --target whisper-server -j "$JOBS" >>"$WORK/whisper.log" 2>&1 \
    || { tail -30 "$WORK/whisper.log" >&2; echo "whisper-server did not build. The last of what the build said is above." >&2; exit 1; }
  rm -rf -- "$WHISPER.partial"
  mkdir -p "$WHISPER.partial"
  cp "$WORK/whisper-build/bin/whisper-server" "$WHISPER.partial/"
  cp "$WORK/whisper-source/LICENSE" "$WHISPER.partial/LICENSE"
  mv "$WHISPER.partial" "$WHISPER"
fi

# ---- The cleanup engine. llama.cpp offers one ready-made.
LLAMA=
for TAG in $(newest_tags ggml-org/llama.cpp '^b[0-9]+$' 4); do
  LLAMA="$CACHE/llama-server-$TAG"
  if [ -x "$LLAMA/llama-server" ]; then
    echo "have     llama-server $TAG"
    break
  fi
  FILE="llama-$TAG-bin-macos-arm64.tar.gz"
  # The newest release may still be on its way up, so the few before it are tried too.
  if curl -fsSL -o "$WORK/$FILE" "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/$FILE" 2>/dev/null; then
    echo "download $FILE"
    mkdir -p "$WORK/llama"
    tar -xzf "$WORK/$FILE" -C "$WORK/llama"
    FOUND=$(find "$WORK/llama" -type f -name llama-server | awk 'NR == 1')
    [ -n "$FOUND" ] || { echo "$FILE has no llama-server in it." >&2; exit 1; }
    rm -rf -- "$LLAMA.partial"
    mkdir -p "$LLAMA.partial"
    # The server and the libraries beside it. The other programs it comes with are not needed.
    cp "$FOUND" "$LLAMA.partial/"
    find "$(dirname "$FOUND")" -maxdepth 1 -name '*.dylib' -exec cp -a {} "$LLAMA.partial/" \;
    LICENCE=$(find "$WORK/llama" -type f -name 'LICENSE*' | awk 'NR == 1')
    [ -n "$LICENCE" ] && cp "$LICENCE" "$LLAMA.partial/LICENSE"
    "$LLAMA.partial/llama-server" --version >/dev/null 2>&1 || { echo "The llama-server in $FILE does not run here." >&2; exit 1; }
    mv "$LLAMA.partial" "$LLAMA"
    break
  fi
  LLAMA=
done
[ -n "$LLAMA" ] && [ -x "$LLAMA/llama-server" ] || { echo "Could not get llama-server." >&2; exit 1; }

mkdir -p "$WORK/engines"
cp -R "$WHISPER" "$WORK/engines/whisper-server"
cp -R "$LLAMA" "$WORK/engines/llama-server"
rm -f "$WORK/engines/whisper-server/LICENSE" "$WORK/engines/llama-server/LICENSE"

LUCID_ENGINES="$WORK/engines" scripts/build-app.sh
APP="dist/Lucid.app"
mkdir -p "$APP/Contents/Resources/LICENSES"
cp "$WHISPER/LICENSE" "$APP/Contents/Resources/LICENSES/whisper.cpp.txt"
[ -f "$LLAMA/LICENSE" ] && cp "$LLAMA/LICENSE" "$APP/Contents/Resources/LICENSES/llama.cpp.txt"
cp LICENSE "$APP/Contents/Resources/LICENSES/Lucid.txt"
# Anything added after signing would break the seal, so the app is signed again.
codesign --force --sign - "$APP"

# The engines must be found from inside the app, wherever the app is put.
FOUND=$("$APP/Contents/MacOS/Lucid" --where | grep -c "Lucid.app/Contents/Resources/engines/" || true)
[ "$FOUND" -ge 2 ] || { "$APP/Contents/MacOS/Lucid" --where >&2; echo "The packed Lucid does not find its own engines." >&2; exit 1; }

ZIP="dist/Lucid-$VERSION-mac-arm64.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "made     $ZIP ($(( $(stat -f %z "$ZIP") / 1048576 )) MB)"
