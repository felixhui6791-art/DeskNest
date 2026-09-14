#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CHANNEL="${1:-beta}"
"$PROJECT_DIR/scripts/build-app.sh" "$CHANNEL"
APP_NAME="$(python3 "$PROJECT_DIR/scripts/distribution.py" get "$CHANNEL" appName)"
open "$PROJECT_DIR/build/$APP_NAME.app"
