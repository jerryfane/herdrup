#!/usr/bin/env bash
#
# Archive the Herdr (Herdrup) iOS app for App Store / TestFlight and, optionally,
# upload it. Runs on the MAC (needs Xcode + xcodegen) — it cannot run on Linux,
# where the app is authored, so this script IS the archive lane, kept in-repo and
# reviewable rather than hidden in Xcode UI. See docs/testflight-lane.md.
#
# Distribution signing is AUTOMATIC: the archive runs with
# `-allowProvisioningUpdates` + an App Store Connect API key, so Xcode creates or
# renews the Apple Distribution certificate and the App Store provisioning profile
# on demand. No certs are committed and none need hand-installing, PROVIDED the API
# key is an App Manager/Admin key (Users and Access -> Integrations).
#
# Usage:
#   ASC_KEY_ID=4X6YN5S8US \
#   ASC_ISSUER_ID=<issuer-uuid> \
#   ASC_KEY_PATH=/path/to/AuthKey_4X6YN5S8US.p8 \
#   scripts/testflight.sh                 # archive + export a signed .ipa (no upload)
#
#   TESTFLIGHT_UPLOAD=1 scripts/testflight.sh   # ...and upload to TestFlight
#
# Upload requires the App Store Connect app record for com.jerryfane.herdr to exist.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="${SCHEME:-Herdr}"
CONFIG="${CONFIG:-Release}"
BUILD_DIR="${BUILD_DIR:-build}"
ARCHIVE="$BUILD_DIR/Herdr.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTS="${EXPORT_OPTS:-ci/ExportOptions.plist}"

# App Store Connect API key — required (fail early with a clear message).
: "${ASC_KEY_ID:?set ASC_KEY_ID, the App Store Connect key id (e.g. 4X6YN5S8US)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID, the App Store Connect issuer uuid}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH, the path to AuthKey_<key-id>.p8}"
[ -f "$ASC_KEY_PATH" ] || { echo "error: ASC_KEY_PATH not found: $ASC_KEY_PATH" >&2; exit 1; }

# Each TestFlight build needs a unique, monotonic build number; default to a
# timestamp. Override with BUILD_NUMBER for a deterministic CI counter.
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }

echo "==> xcodegen generate"
xcodegen generate

echo "==> archive ($CONFIG, build $BUILD_NUMBER)"
xcodebuild archive \
  -project Herdr.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "==> export signed .ipa"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

IPA="$(ls "$EXPORT_DIR"/*.ipa 2>/dev/null | head -1 || true)"
[ -n "$IPA" ] || { echo "error: no .ipa produced in $EXPORT_DIR" >&2; exit 1; }
echo "==> archived + exported: $IPA (build $BUILD_NUMBER)"

if [ "${TESTFLIGHT_UPLOAD:-0}" = "1" ]; then
  # altool looks for AuthKey_<id>.p8 in ~/.appstoreconnect/private_keys (among a
  # few known dirs); place it there so --apiKey resolves without embedding a path.
  KEYDIR="$HOME/.appstoreconnect/private_keys"
  mkdir -p "$KEYDIR"
  cp "$ASC_KEY_PATH" "$KEYDIR/AuthKey_${ASC_KEY_ID}.p8"

  echo "==> validate before upload"
  xcrun altool --validate-app -f "$IPA" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

  echo "==> upload to App Store Connect / TestFlight"
  xcrun altool --upload-app -f "$IPA" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "==> uploaded. It appears in TestFlight after Apple finishes processing."
else
  echo "==> upload SKIPPED. Set TESTFLIGHT_UPLOAD=1 to upload."
  echo "    Upload needs: (1) the App Store Connect app record for"
  echo "    com.jerryfane.herdr, and (2) the API key set to App Manager/Admin."
fi
