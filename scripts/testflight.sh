#!/usr/bin/env bash
#
# Archive the Herdr (Herdrup) iOS app for App Store / TestFlight and, optionally,
# upload it. Runs on the MAC (needs Xcode + xcodegen) — it cannot run on Linux,
# where the app is authored, so this script IS the archive lane, kept in-repo and
# reviewable rather than hidden in Xcode UI. See docs/testflight-lane.md.
#
# SIGNING AND UPLOAD both go through the Mac's signed-in Xcode account (Apple ID).
# `-allowProvisioningUpdates` creates/renews the Apple Distribution certificate +
# App Store provisioning profile from that account session, and `destination:
# upload` distributes through the same account. NO App Store Connect API key is used
# or needed here — deliberately: passing an API key to `-exportArchive` makes it
# perform distribution *signing*, not upload only, which would require the key to
# hold cloud-managed-distribution/provisioning access an individual or non-Admin key
# may lack. (For a fully-headless CI without an interactive account, see the
# alternative in docs/testflight-lane.md: a manually-installed distribution cert +
# profile plus an upload-only Transporter step with the API key.)
#
# Usage:
#   scripts/testflight.sh                         # archive + export a signed .ipa (no upload)
#   TESTFLIGHT_UPLOAD=1 scripts/testflight.sh     # ...and upload to TestFlight
#
# Upload requires the App Store Connect app record for com.jerryfane.herdr to exist.
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
  echo "==> export + upload via the signed-in Xcode account"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist ci/ExportOptions-upload.plist \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates
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
  echo "    Set TESTFLIGHT_UPLOAD=1 to upload. Upload needs the App Store Connect"
  echo "    app record for com.jerryfane.herdr."
fi
