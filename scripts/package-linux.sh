#!/bin/bash
# Makes the Linux downloads: Lucid with its engines inside, so that whoever downloads one
# has nothing to build and no terminal to open.
#
#   dist/lucid_<version>_<arch>.deb           for Ubuntu, Debian and their relatives: open it to install
#   dist/Lucid-<version>-linux-<arch>.tar.gz  for any other Linux: unpack it and open Lucid
#
# The models are not inside: Lucid downloads them itself, from its window, the first time.
#
# Needs what scripts/setup-linux.sh needs, and libcurl's development package:
#   sudo apt-get install libgtk-3-dev libxi-dev libxtst-dev libcurl4-openssl-dev cmake g++ git curl
#
# LUCID_ENGINE_CACHE=folder keeps the engines there between runs. Building one takes minutes.
set -euo pipefail
cd "$(dirname "$0")/.."

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "$1 is required. $2" >&2; exit 1; }
}
need swift "Install it from https://www.swift.org/install/linux."
need git "Install git."
need curl "Install curl."
need cmake "Install cmake and a C++ compiler."
need tar "Install tar."

VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/LucidApp/Desk.swift)
[ -n "$VERSION" ] || { echo "Could not read Lucid's version from Sources/LucidApp/Desk.swift." >&2; exit 1; }
case "$(uname -m)" in
  x86_64) ARCH=x64; DEB_ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64; DEB_ARCH=arm64 ;;
  *) echo "Lucid's downloads are made for x86_64 and arm64, not $(uname -m)." >&2; exit 1 ;;
esac

WORK=$(mktemp -d)
trap 'case "$WORK" in /tmp/*|/var/*) rm -rf -- "$WORK" ;; esac' EXIT
JOBS=$(nproc 2>/dev/null || echo 2)
CACHE="${LUCID_ENGINE_CACHE:-$WORK/engines}"
mkdir -p "$CACHE"

# The newest few of a project's releases, by the names it gives them. Every stage reads
# all it is given: one that stopped early would stop the script.
newest_tags() {
  git ls-remote --tags --refs "https://github.com/$1" | sed 's|.*refs/tags/||' | grep -E "$2" | sort -V -r | awk -v most="$3" 'NR <= most'
}

# ---- The speech engine. whisper.cpp offers nothing ready-made for Linux, so it is built
# here, with a version of its arithmetic for each kind of processor. It chooses among them
# when it runs: one built only for this computer's processor would stop dead on an older one.
WHISPER_TAG=$(newest_tags ggml-org/whisper.cpp '^v[0-9]+\.[0-9]+\.[0-9]+$' 1)
[ -n "$WHISPER_TAG" ] || { echo "Could not find a release of whisper.cpp." >&2; exit 1; }
WHISPER="$CACHE/whisper-server-$WHISPER_TAG-$ARCH"
if [ -x "$WHISPER/whisper-server" ]; then
  echo "have     whisper-server $WHISPER_TAG"
else
  echo "build    whisper-server from whisper.cpp $WHISPER_TAG, for every kind of processor (several minutes)"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$WORK/whisper-source"
  # shellcheck disable=SC2016
  cmake -S "$WORK/whisper-source" -B "$WORK/whisper-build" -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON \
      -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_SDL2=OFF \
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON '-DCMAKE_INSTALL_RPATH=$ORIGIN' >"$WORK/whisper.log" 2>&1 \
    && cmake --build "$WORK/whisper-build" --target whisper-server -j "$JOBS" >>"$WORK/whisper.log" 2>&1 \
    || { tail -30 "$WORK/whisper.log" >&2; echo "whisper-server did not build. The last of what the build said is above." >&2; exit 1; }
  rm -rf -- "$WHISPER.partial"
  mkdir -p "$WHISPER.partial"
  cp "$WORK/whisper-build/bin/whisper-server" "$WHISPER.partial/"
  # The libraries it is made of, beside it, which is where it looks for them.
  find "$WORK/whisper-build" -name '*.so*' -exec cp -a {} "$WHISPER.partial/" \;
  cp "$WORK/whisper-source/LICENSE" "$WHISPER.partial/LICENSE"
  mv "$WHISPER.partial" "$WHISPER"
fi

# ---- The cleanup engine. llama.cpp offers one ready-made that runs on any processor.
LLAMA=
for TAG in $(newest_tags ggml-org/llama.cpp '^b[0-9]+$' 4); do
  LLAMA="$CACHE/llama-server-$TAG-$ARCH"
  if [ -x "$LLAMA/llama-server" ]; then
    echo "have     llama-server $TAG"
    break
  fi
  FILE="llama-$TAG-bin-ubuntu-$ARCH.tar.gz"
  # The newest release may still be on its way up, so the few before it are tried too.
  if curl -fsSL -o "$WORK/$FILE" "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/$FILE" 2>/dev/null; then
    echo "download $FILE ($(( $(stat -c %s "$WORK/$FILE") / 1048576 )) MB)"
    mkdir -p "$WORK/llama"
    tar -xzf "$WORK/$FILE" -C "$WORK/llama"
    FOUND=$(find "$WORK/llama" -type f -name llama-server | awk 'NR == 1')
    [ -n "$FOUND" ] || { echo "$FILE has no llama-server in it." >&2; exit 1; }
    rm -rf -- "$LLAMA.partial"
    mkdir -p "$LLAMA.partial"
    # The server and the libraries beside it. The other programs it comes with are not needed.
    cp "$FOUND" "$LLAMA.partial/"
    find "$(dirname "$FOUND")" -maxdepth 1 -name '*.so*' -exec cp -a {} "$LLAMA.partial/" \;
    LICENCE=$(find "$WORK/llama" -type f -name 'LICENSE*' | awk 'NR == 1')
    [ -n "$LICENCE" ] && cp "$LICENCE" "$LLAMA.partial/LICENSE"
    "$LLAMA.partial/llama-server" --version >/dev/null 2>&1 || { echo "The llama-server in $FILE does not run here." >&2; exit 1; }
    mv "$LLAMA.partial" "$LLAMA"
    break
  fi
  LLAMA=
done
[ -n "$LLAMA" ] && [ -x "$LLAMA/llama-server" ] || { echo "Could not get llama-server." >&2; exit 1; }

# ---- Lucid itself, with Swift's own libraries inside it, so that Swift need not be installed.
echo "build    Lucid $VERSION"
# The linker has a remark about Swift's own library for every file it reads. It is left out.
for PRODUCT in Lucid lucid-cli; do
  swift build -c release --static-swift-stdlib --product "$PRODUCT" 2>&1 | { grep -v "is dangerous, better use" || true; }
done
BIN=$(swift build -c release --static-swift-stdlib --show-bin-path)

APP="$WORK/Lucid"
mkdir -p "$APP/engines" "$APP/LICENSES"
cp "$BIN/Lucid" "$BIN/lucid-cli" "$APP/"
strip --strip-all "$APP/Lucid" "$APP/lucid-cli" 2>/dev/null || true
cp -a "$WHISPER" "$APP/engines/whisper-server"
cp -a "$LLAMA" "$APP/engines/llama-server"
mv "$APP/engines/whisper-server/LICENSE" "$APP/LICENSES/whisper.cpp.txt"
[ -f "$APP/engines/llama-server/LICENSE" ] && mv "$APP/engines/llama-server/LICENSE" "$APP/LICENSES/llama.cpp.txt"
[ -f LICENSE ] && cp LICENSE "$APP/LICENSES/Lucid.txt"
cat > "$APP/LICENSES/README.txt" <<'TEXT'
Lucid comes with these, each under its own licence:

  whisper.cpp, the speech engine        MIT licence: whisper.cpp.txt
                                        https://github.com/ggml-org/whisper.cpp
  llama.cpp, the cleanup engine         MIT licence: llama.cpp.txt
                                        https://github.com/ggml-org/llama.cpp
  The Swift runtime and Foundation      Apache licence 2.0, with the Runtime Library Exception
                                        https://www.swift.org/legal/license.html
  ICU, inside Foundation                Unicode licence
                                        https://www.unicode.org/license.txt

The models Lucid downloads have licences of their own, shown where they are downloaded from.
TEXT
# The engines must be found from inside the folder, wherever the folder is put.
FOUND=$("$APP/lucid-cli" doctor 2>&1 | grep -c "$APP/engines/" || true)
[ "$FOUND" -ge 2 ] || { "$APP/lucid-cli" doctor >&2 || true; echo "The packed Lucid does not find its own engines." >&2; exit 1; }

mkdir -p dist
TARBALL="dist/Lucid-$VERSION-linux-$ARCH.tar.gz"
cat > "$APP/README.txt" <<'TEXT'
Lucid: hold a key, speak, let go.

Open the file named Lucid in this folder. In some file managers that is a double click, and
in others it is a right click and "Run as a Program". Lucid adds itself to your applications
menu, so after the first time you can open it from there. Keep this folder where it is, or
open Lucid once more after moving it.

Lucid's window says what it still needs. The first time, that is its models, which it
downloads itself.
TEXT
tar -czf "$TARBALL" -C "$WORK" Lucid
rm "$APP/README.txt"
echo "made     $TARBALL ($(( $(stat -c %s "$TARBALL") / 1048576 )) MB)"

# ---- The package for Ubuntu and Debian.
if command -v dpkg-deb >/dev/null 2>&1; then
  DEB="$WORK/deb"
  mkdir -p "$DEB/DEBIAN" "$DEB/opt" "$DEB/usr/bin" "$DEB/usr/share/applications" "$DEB/usr/share/doc/lucid"
  cp -a "$APP" "$DEB/opt/lucid"
  ln -s /opt/lucid/lucid-cli "$DEB/usr/bin/lucid-cli"
  # The icon, drawn by Lucid itself, into a folder made for the purpose.
  XDG_DATA_HOME="$WORK/icons" XDG_DATA_DIRS="$WORK/none" "$APP/Lucid" --install-launcher
  cp -a "$WORK/icons/icons" "$DEB/usr/share/icons"
  cat > "$DEB/usr/share/applications/lucid.desktop" <<'TEXT'
[Desktop Entry]
Type=Application
Name=Lucid
GenericName=Dictation
Comment=Hold a key, speak, and clean text appears where your cursor is
Exec=/opt/lucid/Lucid
Icon=lucid
Terminal=false
Categories=Utility;Accessibility;
Keywords=dictation;speech;voice;transcribe;
StartupNotify=false
TEXT
  cp "$APP/LICENSES/README.txt" "$DEB/usr/share/doc/lucid/copyright"
  # The oldest system library this was built against is the oldest it runs with.
  LIBC=$(ldd --version | awk 'NR == 1 { print $NF }')
  cat > "$DEB/DEBIAN/control" <<TEXT
Package: lucid
Version: $VERSION
Section: utils
Priority: optional
Architecture: $DEB_ARCH
Installed-Size: $(du -sk "$DEB" | awk '{ print $1 }')
Depends: libc6 (>= $LIBC), libstdc++6, libgomp1, libgtk-3-0, libcurl4, libxi6, libxtst6, libayatana-appindicator3-1, pulseaudio-utils | pipewire-bin | alsa-utils, xdg-utils
Maintainer: Silicon-Spider <Silicon-Spider@users.noreply.github.com>
Homepage: https://github.com/Silicon-Spider/Lucid
Description: Dictation that runs on this computer
 Hold a key, speak, let go. Clean text appears where your cursor is, in any
 app. Lucid removes the fillers and false starts before the text lands.
 Everything runs on this computer: no audio and no text is sent anywhere.
TEXT
  PACKAGE="dist/lucid_${VERSION}_${DEB_ARCH}.deb"
  dpkg-deb --root-owner-group --build "$DEB" "$PACKAGE" >/dev/null
  echo "made     $PACKAGE ($(( $(stat -c %s "$PACKAGE") / 1048576 )) MB)"
else
  echo "skip     the .deb: dpkg-deb is not installed"
fi
