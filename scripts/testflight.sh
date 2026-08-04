#!/usr/bin/env bash
#
# Archive the Herdr (Herdrup) iOS app for App Store / TestFlight and, optionally,
# upload it. Runs on the MAC (needs Xcode + xcodegen) — it cannot run on Linux,
# where the app is authored, so this script IS the archive lane, kept in-repo and
# reviewable rather than hidden in Xcode UI. See docs/testflight-lane.md.
#
# SIGNING happens through the Mac's signed-in Xcode account (Apple ID). The archive
# runs with `-allowProvisioningUpdates`, so Xcode creates/renews the Apple
# Distribution certificate + App Store profile from that account session — this
# does NOT require the App Store Connect API key to hold provisioning/cloud-signing
# access (which an individual-account or non-Admin key may lack). The API key is
# used ONLY for the upload leg.
#
# Usage:
#   scripts/testflight.sh                         # archive + export a signed .ipa (no upload)
#
#   TESTFLIGHT_UPLOAD=1 \
#   ASC_KEY_ID=REDACTED-KEYID \
#   ASC_ISSUER_ID=<issuer-uuid> \
#   ASC_KEY_PATH=/path/to/AuthKey_REDACTED-KEYID.p8 \
#   scripts/testflight.sh                         # ...and upload to TestFlight
#
# Upload requires the App Store Connect app record for com.jerryfane.herdr to exist
# and the API key to have upload permission (App Manager or Admin).
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="${SCHEME:-Herdr}"
CONFIG="${CONFIG:-Release}"
BUILD_DIR="${BUILD_DIR:-build}"
ARCHIVE="$BUILD_DIR/Herdr.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
UPLOAD="${TESTFLIGHT_UPLOAD:-0}"

# Each TestFlight build needs a unique, monotonic build number. Default to a
# second-precision timestamp; for rapid successive uploads or reproducibility pass
# a durable CI counter via BUILD_NUMBER (the caller owns uniqueness then).
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"

command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }

# Upload credentials are needed ONLY for the upload leg; a plain archive+export is
# a self-contained signing dry-run that needs no API key.
if [ "$UPLOAD" = "1" ]; then
  : "${ASC_KEY_ID:?upload needs ASC_KEY_ID, the App Store Connect key id (e.g. REDACTED-KEYID)}"
  : "${ASC_ISSUER_ID:?upload needs ASC_ISSUER_ID, the App Store Connect issuer uuid}"
  : "${ASC_KEY_PATH:?upload needs ASC_KEY_PATH, the path to AuthKey_<key-id>.p8}"
  [ -f "$ASC_KEY_PATH" ] || { echo "error: ASC_KEY_PATH not found: $ASC_KEY_PATH" >&2; exit 1; }
fi

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
  -allowProvisioningUpdates

if [ "$UPLOAD" = "1" ]; then
  echo "==> export + upload to App Store Connect / TestFlight"
  # destination: upload signs and uploads in one step (no deprecated altool). The
  # API key authenticates the upload only.
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist ci/ExportOptions-upload.plist \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  echo "==> uploaded (build $BUILD_NUMBER). It appears in TestFlight after Apple finishes processing."
else
  echo "==> export signed .ipa (no upload)"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist ci/ExportOptions.plist \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates
  IPA="$(ls "$EXPORT_DIR"/*.ipa 2>/dev/null | head -1 || true)"
  [ -n "$IPA" ] || { echo "error: no .ipa produced in $EXPORT_DIR" >&2; exit 1; }
  echo "==> archived + exported: $IPA (build $BUILD_NUMBER)"
  echo "    Set TESTFLIGHT_UPLOAD=1 (+ ASC_* env) to upload. Upload needs the App"
  echo "    Store Connect app record for com.jerryfane.herdr and an upload-capable key."
fi
