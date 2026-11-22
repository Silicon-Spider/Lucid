#!/bin/bash
# Installs Lucid's engines and downloads its models.
# Safe to run again: finished downloads are skipped and partial ones resume.
set -euo pipefail

MODELS="$HOME/Library/Application Support/Lucid/models"
HF="https://huggingface.co"
WITH_GENERAL=0

for arg in "$@"; do
  case "$arg" in
    --with-general) WITH_GENERAL=1 ;;
    -h|--help)
      echo "usage: scripts/setup.sh [--with-general]"
      echo
      echo "Installs whisper.cpp and llama.cpp with Homebrew, then downloads:"
      echo "  - the speech model, Whisper large-v3-turbo (547 MB)"
      echo "  - the cleanup model, S1-mini by Superwhisper (462 MB)"
      echo "  --with-general also downloads Llama 3.2 3B (1.9 GB), used for the Medium level."
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required. Install it from https://brew.sh and run this again." >&2
  exit 1
fi

for formula in whisper-cpp llama.cpp; do
  if brew list --formula "$formula" >/dev/null 2>&1; then
    echo "have     $formula"
  else
    echo "install  $formula"
    brew install "$formula"
  fi
done

for binary in whisper-server llama-server; do
  if ! command -v "$binary" >/dev/null 2>&1; then
    echo "$binary is not on the PATH after installing with Homebrew." >&2
    exit 1
  fi
done

mkdir -p "$MODELS"

# fetch URL NAME SIZE_IN_BYTES
fetch() {
  local url="$1" name="$2" size="$3"
  local out="$MODELS/$name"
  if [ -f "$out" ] && [ "$(stat -f%z "$out")" -eq "$size" ]; then
    echo "have     $name"
    return 0
  fi
  echo "download $name ($((size / 1048576)) MB)"
  local attempt=0
  while [ "$attempt" -lt 50 ]; do
    attempt=$((attempt + 1))
    curl -fL -C - --connect-timeout 30 --speed-limit 512 --speed-time 90 --progress-bar \
      -o "$out.part" "$url" || true
    local have=0
    if [ -f "$out.part" ]; then have=$(stat -f%z "$out.part"); fi
    if [ "$have" -eq "$size" ]; then
      mv "$out.part" "$out"
      return 0
    fi
    if [ "$have" -gt "$size" ]; then rm -f "$out.part"; fi
    echo "  connection dropped at $((have / 1048576)) MB, resuming"
    sleep 3
  done
  echo "Could not finish downloading $name. Run this script again to resume." >&2
  return 1
}

fetch "$HF/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin" \
  ggml-large-v3-turbo-q5_0.bin 574041195
fetch "$HF/superwhisper/s1-mini-GGUF/resolve/main/s1-mini-q4_k_m.gguf" \
  s1-mini-q4_k_m.gguf 484219808
if [ "$WITH_GENERAL" -eq 1 ]; then
  fetch "$HF/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf" \
    Llama-3.2-3B-Instruct-Q4_K_M.gguf 2019377696
fi

echo
echo "Setup complete. Check it with: swift run lucid-cli doctor"
