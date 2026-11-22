#!/bin/bash
# Builds and runs the unit tests. Pass a suite name to run only that suite.
set -euo pipefail
cd "$(dirname "$0")/.."
swift run LucidCoreTests "$@"
