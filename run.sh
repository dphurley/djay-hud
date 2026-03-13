#!/bin/bash
cd "$(dirname "$0")"
swift build -q 2>/dev/null && .build/debug/djay-hud "$@"
