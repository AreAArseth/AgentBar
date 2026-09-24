#!/bin/bash
# Builds the feature-GIF generator against the app's own sources and runs it.
# Usage: Scripts/demo/make-gifs.sh [out-dir]   (default: docs/assets)
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-docs/assets}"
BIN="$(mktemp -d)/feature-gifs"
mkdir -p "$OUT"
swiftc -target arm64-apple-macos12.0 \
  $(find Sources/AgentBar -name "*.swift" ! -name "main.swift") \
  Scripts/demo/feature-gifs.swift -o "$BIN"
"$BIN" "$OUT"
