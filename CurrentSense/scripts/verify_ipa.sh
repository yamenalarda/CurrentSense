#!/usr/bin/env bash
# Usage: verify_ipa.sh <ipa> <bundle-id> <build-number> <source-sha>
# Fails if the IPA structure, bundle metadata, executable or embedded revision are wrong.
set -euo pipefail
IPA="$1"; BUNDLE_ID="$2"; BUILD="$3"; SHA="$4"
T="$(mktemp -d)"
unzip -q "$IPA" -d "$T"
APP="$(ls -d "$T"/Payload/*.app 2>/dev/null | head -n1)"
[ -n "$APP" ] || { echo "FAIL: no Payload/*.app"; exit 1; }
PL="$APP/Info.plist"
get() { plutil -extract "$1" raw -o - "$PL"; }

[ "$(get CFBundleIdentifier)" = "$BUNDLE_ID" ] || { echo "FAIL: bundle id $(get CFBundleIdentifier)"; exit 1; }
[ "$(get CFBundleVersion)" = "$BUILD" ] || { echo "FAIL: build number $(get CFBundleVersion) != $BUILD"; exit 1; }
[ "$(get CSSourceRevision)" = "$SHA" ] || { echo "FAIL: embedded revision $(get CSSourceRevision) != $SHA"; exit 1; }
EXE="$APP/$(get CFBundleExecutable)"
[ -f "$EXE" ] || { echo "FAIL: executable missing"; exit 1; }
lipo -archs "$EXE" | grep -q arm64 || { echo "FAIL: executable has no arm64 slice"; exit 1; }
[ ! -f "$APP/embedded.mobileprovision" ] || { echo "FAIL: unexpected provisioning profile (not an unsigned build)"; exit 1; }
if strings "$EXE" | grep -q "UITestSyntheticSensor"; then echo "FAIL: DEBUG synthetic sensor present in release binary"; exit 1; fi

echo "bundle id        : $(get CFBundleIdentifier)"
echo "version / build  : $(get CFBundleShortVersionString) / $(get CFBundleVersion)"
echo "source revision  : $(get CSSourceRevision)"
echo "min iOS          : $(get MinimumOSVersion)"
echo "executable       : $(basename "$EXE") ($(lipo -archs "$EXE"))"
echo "signature        : $(codesign -dv "$APP" 2>&1 | head -n1 || true)"
echo "IPA size         : $(du -h "$IPA" | cut -f1)"
rm -rf "$T"
echo "IPA verification PASSED"
