#!/usr/bin/env bash
# Runs one simulator shard of the CI device suite. ci.yml runs the shards as
# parallel jobs; each job has already built the app and test bundles into .build-dd
# (build-for-testing) and exported IPHONE_UDID / IPAD_UDID.
#
#   iphone-terminal  TERMINAL_CLASSES, then ChatViewTests and PagingTests in rounds of
#                    their own, on iPhone
#   iphone-app       HerdrFontTests, then StatusMotionTests in its own round, then
#                    every other HerdrUITests class on iPhone, then the SwiftTerm UIKit API
#                    tests on iPhone
#   ipad             iPad-specific rounds, then the SwiftTerm UIKit API tests on iPad
#   settings-build   optimized simulator build; CI caches its products before testing
#   settings-gram    iPad Settings resize/resume regression using that Distribution build
#                    with the device-sized stack (herdrup#416), even on cache hits; then
#                    GramTests on the iPhone with the Debug build
#   focused          ONLY_SUITE on ONLY_DEVICE (manual dispatch)
#
# The iPhone rounds are complementary BY CONSTRUCTION: iphone-terminal runs exactly
# TERMINAL_CLASSES plus ChatViewTests and PagingTests and settings-gram runs GramTests,
# while iphone-app skips those same identifiers, so a new test class lands in iphone-app
# without anyone listing it. A misspelled or renamed entry would silently drop that class, so
# iphone-terminal fails unless its result bundles show every listed class executed tests.
set -uo pipefail

shard="${1:?usage: ui-shard.sh iphone-terminal|iphone-app|ipad|settings-build|settings-gram|focused}"
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

# Build the optimized simulator products; tests use the generated .xctestrun below.
# Only the selected simulator architecture runs this test. Distribution otherwise builds
# an unused x86_64 copy on the arm64 hosted runner (baseline 38829646885).
SETTINGS_PROJECT=(-project Herdr.xcodeproj -scheme Herdr -configuration Distribution
  -derivedDataPath .build-dd-settings-stack -clonedSourcePackagesDirPath SourcePackages
  ENABLE_TESTABILITY=YES 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG'
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO)

recorder=
stop_recording() {
  if [ -n "$recorder" ]; then
    kill -INT "$recorder" 2>/dev/null || true
    wait "$recorder" || true
    recorder=
  fi
}
trap stop_recording EXIT

# Bound the entire boot request + readiness wait, not just xcodebuild. A stuck
# CoreSimulator must leave time for receipt upload. TERM gets 15 s before KILL.
# First-boot data migration took 5m41s in run 38916529804. Each device's first (cold)
# boot gets 10m; later readiness checks of the same device keep the shorter 5m.
# Per device, because settings-gram cold-boots the iPad and then the iPhone.
cold_booted=" "
boot_simulator() {
  local udid="$1" log="$2" status=0 budget=10m
  case "$cold_booted" in *" $udid "*) budget=5m ;; esac
  cold_booted="$cold_booted$udid "
  "$TIMEOUT_BIN" --signal=TERM --kill-after=15s "$budget" bash -c '
    # An already-booted device rejects boot; bootstatus is the readiness authority.
    xcrun simctl boot "$1" || true
    exec xcrun simctl bootstatus "$1" -b
  ' _ "$udid" 2>&1 | tee "$log" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "::error::simulator $udid failed to become ready within $budget (exit $status); see $log"
    return 1
  fi
}

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
  boot_simulator "$udid" "TestReceipts/$label-boot.log" || return 1
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

# Fails unless every class named after the bundle executed at least one test in it.
check_classes_ran() {
  local bundle="$1"
  shift
  xcrun xcresulttool get test-results tests --path "$bundle" 2>/dev/null |
    python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    print("::error::no readable result bundle to check " + ", ".join(sys.argv[1:]) + " against")
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
    print(f"::error::{name} executed no tests in this round; the listed name no longer matches a class, so that class falls through to the iphone-app catch-all round")
sys.exit(1 if missing else 0)
' "$@"
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
    boot_simulator "$udid" "../../TestReceipts/$label-boot.log" || exit 1
    if ! "$TIMEOUT_BIN" --signal=INT 15m xcodebuild test-without-building -scheme "$scheme" \
        -destination "platform=iOS Simulator,id=$udid" \
        -parallel-testing-enabled NO \
        -test-timeouts-enabled YES \
        -only-testing:SwiftTermTests/TerminalViewGeometryTests \
        -derivedDataPath ../../.build-dd-swiftterm \
        -resultBundlePath "../../TestReceipts/$label-first.xcresult" \
        CODE_SIGNING_ALLOWED=NO 2>&1 | tee "../../TestReceipts/$label-first.log" | xcbeautify; then
      echo "::error::$label first run failed; collecting raw diagnostics without erasing failure"
      boot_simulator "$udid" "../../TestReceipts/$label-diagnostic-boot.log" || exit 1
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
    check_classes_ran TestReceipts/iPhoneTerminal-first.xcresult "${TERMINAL_CLASSES[@]}" || failed=1
    # GramTests run in settings-gram: after #445 this shard had ~40 min of tests against
    # ~26 (iphone-app) and ~24 (ipad), and settings-stack finished in ~13 min (runs
    # 39128731625, 39132955146, 39137628334).
    # ChatViewTests (#485, ~3.5 min on a hosted runner) run here: in the app round they
    # pushed iPhoneApp to 29 min of tests against its 30 m budget, which run 39930335960
    # exceeded. This shard had ~18 min of tests in that run against 40 m.
    run_suite iPhoneChat "$IPHONE_UDID" 10m -only-testing:HerdrUITests/ChatViewTests || failed=1
    check_classes_ran TestReceipts/iPhoneChat-first.xcresult ChatViewTests || failed=1
    # PagingTests (~4.3 min) run here too: every class in the app round slowed together
    # from run to run (23.7, 26.9 and 29.0 min of tests in runs 39938860577, 39954390114
    # and 39966934030), and 39966934030 ran out of the 30 m on the last class. This shard
    # had ~26 min of tests in its slowest recent run (39944992620) against 40 m + 10 m.
    run_suite iPhonePaging "$IPHONE_UDID" 10m -only-testing:HerdrUITests/PagingTests || failed=1
    check_classes_ran TestReceipts/iPhonePaging-first.xcresult PagingTests || failed=1
    ;;
  iphone-app)
    run_suite font-contract "$IPHONE_UDID" 10m -only-testing:HerdrFontTests || failed=1
    # StatusMotionTests photograph shapes over time and wait out tab switches (~3.5 min on
    # a slow hosted runner): with them in the app round, #433's run 38703928881 ran out of
    # its 30 m on the last class.
    run_suite iPhoneStatusMotion "$IPHONE_UDID" 10m -only-testing:HerdrUITests/StatusMotionTests || failed=1
    skip=(-skip-testing:HerdrUITests/GramTests -skip-testing:HerdrUITests/StatusMotionTests
      -skip-testing:HerdrUITests/ChatViewTests -skip-testing:HerdrUITests/PagingTests)
    for class in "${TERMINAL_CLASSES[@]}"; do skip+=("-skip-testing:HerdrUITests/$class"); done
    run_suite iPhoneApp "$IPHONE_UDID" 30m -only-testing:HerdrUITests "${skip[@]}" || failed=1
    swiftterm_api iPhone "$IPHONE_UDID" || failed=1
    ;;
  ipad)
    boot_simulator "$IPAD_UDID" TestReceipts/iPadRecording-boot.log || exit 1
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
    # Run 38862083708/4 spent 14m on passing cases before the old 15m cap cut off launch.
    # Leave room for the remaining cases; individual test limits and failures are unchanged.
    run_suite iPadControl "$IPAD_UDID" 20m -only-testing:HerdrUITests/TerminalControlTests || failed=1
    run_suite iPadSelectAgent "$IPAD_UDID" 5m -only-testing:HerdrUITests/SelectAgentFieldTests || failed=1
    run_suite iPadAgentListChrome "$IPAD_UDID" 5m -only-testing:HerdrUITests/AgentListChromeTests || failed=1
    swiftterm_api iPad "$IPAD_UDID" || failed=1
    ;;
  settings-build)
    # Build before booting: compiler and simulator compete for the hosted runner's CPUs.
    "$TIMEOUT_BIN" --signal=INT --kill-after=15s 40m \
        xcodebuild build-for-testing "${SETTINGS_PROJECT[@]}" \
        -destination "platform=iOS Simulator,id=$IPAD_UDID" \
        -only-testing:HerdrUITests/SettingsTests/testCompactSettingsSurviveResizeAndResume \
        2>&1 | tee TestReceipts/settings-device-stack-build.log | xcbeautify || failed=1
    ;;
  settings-gram)
    # Distribution, so the optimizer produces the frame sizes that overflowed a
    # device's 1008 KiB main stack; project.yml gives simulator builds that stack.
    # DEBUG keeps the screenshot fixtures; testability lets the UI tests attach.
    # The test-run file uses __TESTROOT__ paths, so Build/Products is self-contained.
    # Never infer a pass from a cache hit or fall back to a different configuration.
    # A missing prerequisite fails the shard but still lets GramTests below run: they
    # need neither the iPad nor the Distribution products.
    settings_runs=(.build-dd-settings-stack/Build/Products/Herdr_*.xctestrun)
    if [ "${#settings_runs[@]}" -ne 1 ] || [ ! -f "${settings_runs[0]}" ]; then
      echo "::error::expected one optimized Settings .xctestrun in Build/Products"
      failed=1
    elif ! boot_simulator "$IPAD_UDID" TestReceipts/settings-device-stack-boot.log; then
      failed=1
    else
      xcrun simctl uninstall "$IPAD_UDID" com.jerryfane.herdr 2>/dev/null || true
      xcrun simctl uninstall "$IPAD_UDID" com.jerryfane.herdr.uitests.xctrunner 2>/dev/null || true
      "$TIMEOUT_BIN" --signal=INT 40m xcodebuild test-without-building -xctestrun "${settings_runs[0]}" \
          -destination "platform=iOS Simulator,id=$IPAD_UDID" \
          -parallel-testing-enabled NO \
          -test-timeouts-enabled YES \
          -default-test-execution-time-allowance 300 \
          -maximum-test-execution-time-allowance 600 \
          -resultBundlePath TestReceipts/settings-device-stack.xcresult \
          -only-testing:HerdrUITests/SettingsTests/testCompactSettingsSurviveResizeAndResume \
          2>&1 | tee TestReceipts/settings-device-stack.log | xcbeautify || failed=1
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
    fi
    # Then GramTests on the iPhone with the Debug build. The iPad is shut down first: the
    # hosted runner has 7 GB, and a second booted simulator adds to the memory pressure
    # measured during launch stalls (herdrup#418). Budget: run 39608758941 (39 GramTests,
    # ~17% slower runner) spent 21.7 min in 36 finished cases and hit the old 25m with
    # two cases left; 35m leaves room for the suite to grow.
    xcrun simctl shutdown "$IPAD_UDID" >/dev/null 2>&1 || true
    run_suite iPhoneGram "$IPHONE_UDID" 35m -only-testing:HerdrUITests/GramTests || failed=1
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
