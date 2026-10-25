#!/usr/bin/env bash
# Wraps the .app from an unsigned xcarchive into an IPA: Payload/<App>.app zipped.
set -euo pipefail
ARCHIVE="${1:-build/CurrentSense.xcarchive}"
OUT="${2:-build/CurrentSense-unsigned.ipa}"
APP="$ARCHIVE/Products/Applications/CurrentSense.app"
[ -d "$APP" ] || { echo "ERROR: $APP not found"; exit 1; }
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
rm -f "$OUT"
( cd "$STAGE" && zip -qry "$OLDPWD/$OUT" Payload )
rm -rf "$STAGE"
echo "Created $OUT"
