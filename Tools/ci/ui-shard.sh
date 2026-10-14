#!/usr/bin/env bash
# Runs one simulator shard of the CI device suite. ci.yml runs the shards as
# parallel jobs; each job has already built the app and test bundles into .build-dd
# (build-for-testing) and exported IPHONE_UDID / IPAD_UDID.
#
#   iphone-terminal  TERMINAL_CLASSES on iPhone
#   iphone-app       HerdrFontTests, then GramTests in their own round, then every other
#                    HerdrUITests class on iPhone, then the SwiftTerm UIKit API tests on iPhone
#   ipad             iPad-specific rounds, then the SwiftTerm UIKit API tests on iPad
#   settings-stack   optimized Distribution build with the device-sized stack, then the
#                    iPad Settings resize/resume regression (herdrup#416)
#   focused          ONLY_SUITE on ONLY_DEVICE (manual dispatch)
#
# The two iPhone shards are complementary BY CONSTRUCTION: one runs exactly
# TERMINAL_CLASSES, the other runs the whole bundle with the same identifiers skipped,
# so a new test class lands in iphone-app without anyone listing it. A misspelled or
# renamed entry would silently drop that class from both shards, so iphone-terminal
# fails unless its result bundle shows every listed class executed tests.
set -uo pipefail

shard="${1:?usage: ui-shard.sh iphone-terminal|iphone-app|ipad|focused}"
TERMINAL_CLASSES=(TerminalControlTests TerminalResizeTests TerminalSearchTests TerminalSelectionTests)
mkdir -p TestReceipts

TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
if [ -z "$TIMEOUT_BIN" ]; then
  echo "::error::no timeout binary; per-suite budgets would be unenforceable"
  exit 1
fi

PROJECT=(-project Herdr.xcodeproj -scheme Herdr
  -derivedDataPath .build-dd -clonedSourcePackagesDirPath SourcePackages
  CODE_SIGNING_ALLOWED=NO)

recorder=
stop_recording() {
  if [ -n "$recorder" ]; then
    kill -INT "$recorder" 2>/dev/null || true
    wait "$recorder" || true
    recorder=
  fi
}
trap stop_recording EXIT

# Prints one -only-testing argument per failed test case in an .xcresult.
failed_tests() {
  xcrun xcresulttool get test-results tests --path "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
def walk(node, bundle):
    if node.get("nodeType") in ("UI test bundle", "Unit test bundle"):
        bundle = node.get("name")
    if node.get("nodeType") == "Test Case" and node.get("result") == "Failed" and bundle:
        print("-only-testing:%s/%s" % (bundle, node["nodeIdentifier"].removesuffix("()")))
    for child in node.get("children", []):
        walk(child, bundle)
for node in data.get("testNodes", []):
    walk(node, None)
'
}

run_suite() {
  local label="$1" udid="$2" budget="$3"
  shift 3
  local status=0
  # Boot outside the test deadline. Booting during the build was measured to slow both.
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null || return 1
  # A WALL-CLOCK BOUND PER INVOCATION, so one wedged case cannot eat the job budget
  # and take the receipt upload down with it. Per-case allowances make xcodebuild
  # fail a stuck test with diagnostics instead of blocking to the deadline.
  "$TIMEOUT_BIN" --signal=INT "$budget" xcodebuild test-without-building "${PROJECT[@]}" \
      -destination "platform=iOS Simulator,id=$udid" \
      -parallel-testing-enabled NO \
      -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 300 \
      -maximum-test-execution-time-allowance 600 \
      -resultBundlePath "TestReceipts/$label-first.xcresult" \
      "$@" 2>&1 | tee "TestReceipts/$label-first.log" | xcbeautify || status=$?
  [ "$status" -eq 0 ] && return 0
  stop_recording
  if [ "$status" -eq 124 ] || [ "$status" -eq 130 ]; then
    # A timeout is a failure on its own evidence; a rerun would spend the budget again.
    echo "::error::$label exceeded its ${budget} budget; see TestReceipts/$label-first.log"
    return 1
  fi
  echo "::error::$label first run failed; the failure stands. Rerunning only the failed tests for raw diagnostics"
  local failed
  failed=$(failed_tests "TestReceipts/$label-first.xcresult")
  if [ -z "$failed" ]; then
    echo "::warning::$label: no failed test case recorded in the result bundle; no diagnostic rerun"
    return 1
  fi
  echo "$failed" | tee "TestReceipts/$label-diagnostic-selection.txt"
  # Diagnostics only: the failed tests usually rerun in 1-3 min. A short cap keeps a
  # pathological rerun from eating the job budget that the receipt upload needs.
  # shellcheck disable=SC2086 # one -only-testing argument per line
  "$TIMEOUT_BIN" --signal=INT 10m xcodebuild test-without-building "${PROJECT[@]}" \
      -destination "platform=iOS Simulator,id=$udid" \
      -parallel-testing-enabled NO \
      -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 300 \
      -maximum-test-execution-time-allowance 600 \
      -resultBundlePath "TestReceipts/$label-diagnostic.xcresult" \
      $failed 2>&1 | tee "TestReceipts/$label-diagnostic.log" >/dev/null || true
  return 1
}

# Fails unless every TERMINAL_CLASSES entry executed at least one test in the bundle.
check_classes_ran() {
  xcrun xcresulttool get test-results tests --path "$1" 2>/dev/null |
    python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    print("::error::no readable result bundle to check the terminal classes against")
    sys.exit(1)
ran = set()
def walk(node, suite):
    if node.get("nodeType") == "Test Suite":
        suite = node.get("name")
    if node.get("nodeType") == "Test Case" and node.get("result") != "Skipped" and suite:
        ran.add(suite)
    for child in node.get("children", []):
        walk(child, suite)
for node in data.get("testNodes", []):
    walk(node, None)
missing = [name for name in sys.argv[1:] if name not in ran]
for name in missing:
    print(f"::error::TERMINAL_CLASSES entry {name} executed no tests; it would run in neither iPhone shard")
sys.exit(1 if missing else 0)
' "${TERMINAL_CLASSES[@]}"
}

swiftterm_api() {
  local device="$1" udid="$2"
  (
    cd Vendor/SwiftTerm || exit 1
    xcodebuild -list -json > ../../TestReceipts/SwiftTermSchemes.json
    scheme=$(python3 - <<'PY'
import json
with open("../../TestReceipts/SwiftTermSchemes.json") as source:
    result = json.load(source)
schemes = next((result[key]["schemes"] for key in ("workspace", "project") if key in result), [])
for candidate in ("SwiftTerm", "SwiftTerm-Package"):
    if candidate in schemes:
        print(candidate)
        break
else:
    raise SystemExit("::error::SwiftTerm package test scheme unavailable")
PY
    ) || exit 1
    # Build outside the timed test window.
    if ! "$TIMEOUT_BIN" --signal=INT 10m xcodebuild build-for-testing -scheme "$scheme" \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath ../../.build-dd-swiftterm \
        CODE_SIGNING_ALLOWED=NO 2>&1 | tee "../../TestReceipts/SwiftTermUIKit-$device-build.log" | xcbeautify; then
      echo "::error::SwiftTerm test build failed; see TestReceipts/SwiftTermUIKit-$device-build.log"
      exit 1
    fi
    label="SwiftTermUIKit-$device"
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    if ! "$TIMEOUT_BIN" --signal=INT 15m xcodebuild test-without-building -scheme "$scheme" \
        -destination "platform=iOS Simulator,id=$udid" \
        -parallel-testing-enabled NO \
        -test-timeouts-enabled YES \
        -only-testing:SwiftTermTests/TerminalViewGeometryTests \
        -derivedDataPath ../../.build-dd-swiftterm \
        -resultBundlePath "../../TestReceipts/$label-first.xcresult" \
        CODE_SIGNING_ALLOWED=NO 2>&1 | tee "../../TestReceipts/$label-first.log" | xcbeautify; then
      echo "::error::$label first run failed; collecting raw diagnostics without erasing failure"
      xcrun simctl boot "$udid" 2>/dev/null || true
      xcrun simctl bootstatus "$udid" -b >/dev/null
      "$TIMEOUT_BIN" --signal=INT 15m xcodebuild test-without-building -scheme "$scheme" \
          -destination "platform=iOS Simulator,id=$udid" \
          -parallel-testing-enabled NO \
          -test-timeouts-enabled YES \
          -only-testing:SwiftTermTests/TerminalViewGeometryTests \
          -derivedDataPath ../../.build-dd-swiftterm \
          -resultBundlePath "../../TestReceipts/$label-diagnostic.xcresult" \
          CODE_SIGNING_ALLOWED=NO 2>&1 | tee "../../TestReceipts/$label-diagnostic.log" >/dev/null || true
      exit 1
    fi
  )
}

failed=0
case "$shard" in
  iphone-terminal)
    only=()
    for class in "${TERMINAL_CLASSES[@]}"; do only+=("-only-testing:HerdrUITests/$class"); done
    run_suite iPhoneTerminal "$IPHONE_UDID" 40m "${only[@]}" || failed=1
    check_classes_ran TestReceipts/iPhoneTerminal-first.xcresult || failed=1
    ;;
  iphone-app)
    run_suite font-contract "$IPHONE_UDID" 10m -only-testing:HerdrFontTests || failed=1
    # Gram has its own round and budget. In one 40 m round with the rest of the app, a green
    # run already used ~36 m of test time, and a slower runner ran out (herdrup#430, run
    # 38521782241: 87 of ~100 tests done at 40 m). Same tests, same total time.
    run_suite iPhoneGram "$IPHONE_UDID" 25m -only-testing:HerdrUITests/GramTests || failed=1
    skip=(-skip-testing:HerdrUITests/GramTests)
    for class in "${TERMINAL_CLASSES[@]}"; do skip+=("-skip-testing:HerdrUITests/$class"); done
    run_suite iPhoneApp "$IPHONE_UDID" 30m -only-testing:HerdrUITests "${skip[@]}" || failed=1
    swiftterm_api iPhone "$IPHONE_UDID" || failed=1
    ;;
  ipad)
    xcrun simctl boot "$IPAD_UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$IPAD_UDID" -b >/dev/null
    # Parallel test clones are disabled, so the video records the tested device.
    xcrun simctl io "$IPAD_UDID" recordVideo TestReceipts/terminal-resize-iPad.mp4 \
      > TestReceipts/terminal-resize-iPad-video.log 2>&1 &
    recorder=$!
    run_suite iPadResize "$IPAD_UDID" 25m -only-testing:HerdrUITests/TerminalResizeTests || failed=1
    stop_recording
    if [ ! -s TestReceipts/terminal-resize-iPad.mp4 ]; then
      echo "::warning::iPad video unavailable; consult recording log and xcresult screenshots"
    fi
    # The iPhone shards keep their coordinate/keyboard receipts; these rounds cover
    # iPad's hardware-keyboard prerequisite and the iPad-only detail column.
    run_suite iPadControl "$IPAD_UDID" 15m -only-testing:HerdrUITests/TerminalControlTests || failed=1
    run_suite iPadSelectAgent "$IPAD_UDID" 5m -only-testing:HerdrUITests/SelectAgentFieldTests || failed=1
    run_suite iPadAgentListChrome "$IPAD_UDID" 5m -only-testing:HerdrUITests/AgentListChromeTests || failed=1
    swiftterm_api iPad "$IPAD_UDID" || failed=1
    ;;
  settings-stack)
    # Distribution, so the optimizer produces the frame sizes that overflowed a
    # device's 1008 KiB main stack; project.yml gives simulator builds that stack.
    # DEBUG keeps the screenshot fixtures; testability lets the UI tests attach.
    xcrun simctl boot "$IPAD_UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$IPAD_UDID" -b >/dev/null
    xcrun simctl uninstall "$IPAD_UDID" com.jerryfane.herdr 2>/dev/null || true
    xcrun simctl uninstall "$IPAD_UDID" com.jerryfane.herdr.uitests.xctrunner 2>/dev/null || true
    "$TIMEOUT_BIN" --signal=INT 40m xcodebuild test \
        -project Herdr.xcodeproj -scheme Herdr -configuration Distribution \
        -destination "platform=iOS Simulator,id=$IPAD_UDID" \
        -derivedDataPath .build-dd-settings-stack \
        -clonedSourcePackagesDirPath SourcePackages \
        -parallel-testing-enabled NO \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 300 \
        -maximum-test-execution-time-allowance 600 \
        -resultBundlePath TestReceipts/settings-device-stack.xcresult \
        -only-testing:HerdrUITests/SettingsTests/testCompactSettingsSurviveResizeAndResume \
        ENABLE_TESTABILITY=YES 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG' \
        CODE_SIGNING_ALLOWED=NO 2>&1 | tee TestReceipts/settings-device-stack.log | xcbeautify || failed=1
    # XCTest activation can restart a crashed app and still report a pass.
    # Without a readable export the guard cannot tell, so that fails the shard too.
    if ! xcrun xcresulttool export attachments \
        --path TestReceipts/settings-device-stack.xcresult \
        --output-path TestReceipts/settings-device-stack-crash-check >/dev/null; then
      echo "::error::could not export the Settings regression's attachments to check for crashes"
      failed=1
    else
      crashes=$(find TestReceipts/settings-device-stack-crash-check -name '*.ips')
      if [ -n "$crashes" ]; then
        echo "::error::Crashes attached to the Settings regression: $crashes"
        failed=1
      else
        echo "Settings device-stack regression: no crash reports attached"
      fi
    fi
    ;;
  focused)
    case "${ONLY_DEVICE:-iphone}" in
      ipad) label=iPad; udid="$IPAD_UDID" ;;
      *)    label=iPhone; udid="$IPHONE_UDID" ;;
    esac
    echo "::notice::focused dispatch: HerdrUITests/$ONLY_SUITE on $label only"
    run_suite "$label-$ONLY_SUITE" "$udid" 25m "-only-testing:HerdrUITests/$ONLY_SUITE" || failed=1
    ;;
  *)
    echo "::error::unknown shard $shard"
    exit 1
    ;;
esac
exit "$failed"
