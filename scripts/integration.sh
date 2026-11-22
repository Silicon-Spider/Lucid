#!/bin/bash
# Runs the whole pipeline on synthesised speech: speech to text, then cleanup.
# Needs the engines and models from scripts/setup.sh. Extra arguments go to lucid-cli dictate.
set -euo pipefail
cd "$(dirname "$0")/.."

CLIPS="$(mktemp -d)"
trap 'rm -rf "$CLIPS"' EXIT

clip() {
  say --file-format=WAVE --data-format=LEI16@16000 -o "$CLIPS/$1.wav" "$2"
}

clip 1-short 'Sounds good, see you then.'
clip 2-correction 'Um, so I was thinking we could, uh, meet at two, actually no, make that three, at the usual place.'
clip 3-question 'What is the capital of France, and, um, what is its population?'
clip 4-ramble 'Okay so, um, here is the plan for the launch. First, we need to, uh, finalise the budget, which I think is about fifty thousand, no wait, sixty thousand dollars. Second, um, we need a timeline from the engineering team, and I mean a real one, not, like, a rough guess. Third, you know, we should get sign off from legal before we announce anything.'

swift build -c release 2>&1 | tail -1
swift run -c release lucid-cli dictate "$@" "$CLIPS"/*.wav
