#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

swift build -c release
quit_running_app

APP="dist/$APP_NAME.app"
make_bundle .build/release/$APP_NAME "$APP" "0"

IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}"
sign_app "$APP" "$IDENTITY"
echo "Built $APP $VERSION (signed with: $IDENTITY)"
