#!/bin/bash
# Local build: dist/TinyHand.app for the current Mac, signed with your Apple
# Development identity (a stable identity keeps the Accessibility grant across
# rebuilds). For a distributable build, use release.sh.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

swift build -c release
quit_running_app

APP="dist/$APP_NAME.app"
make_bundle .build/release/$APP_NAME "$APP" "0"

IDENTITY="${CODESIGN_IDENTITY:-Apple Development}"
sign_app "$APP" "$IDENTITY"
echo "Built $APP $VERSION (signed with: $IDENTITY)"
