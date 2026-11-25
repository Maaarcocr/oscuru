#!/usr/bin/env bash
# Run the UI tests on an iPhone simulator, once per shipped language.
# UI tests (-ui-testing) use a sample photo and a played-back model, so nothing touches the network.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS tests require macOS, Xcode, and an installed iPhone simulator runtime." >&2
  exit 1
fi
for tool in xcodegen xcodebuild xcrun python3; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
[[ -f ios/project.yml ]] || { echo "No iOS app project exists yet (ios/project.yml)." >&2; exit 1; }
if [[ -z "${SIMULATOR_UDID:-}" ]]; then
  SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
  export SDK_VERSION
  SIMULATOR_UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, os, re, sys
def version(value):
    return tuple(int(part) for part in re.findall(r"\d+", value))
sdk = version(os.environ["SDK_VERSION"])
catalog = json.load(sys.stdin)["devices"]
choices = [(runtime, device) for runtime, devices in catalog.items()
           if "iOS" in runtime and version(runtime.split("iOS-")[-1]) <= sdk
           for device in devices if device.get("isAvailable") and "iPhone" in device["name"]]
if not choices:
    raise SystemExit("No available iPhone simulator; install an iOS runtime in Xcode Settings")
# An ordinary numbered iPhone first (not an SE, a Max or a folding one: the screenshots are read
# as the phone most people hold), then a recent runtime; a booted device avoids a cold boot.
def ordinary(name):
    return bool(re.fullmatch(r"iPhone \d+( Pro)?", name))
choices.sort(key=lambda pair: (
    ordinary(pair[1]["name"]),
    version(pair[0].split("iOS-")[-1]),
    pair[1].get("state") == "Booted",
    "SE" not in pair[1]["name"],
    version(pair[1]["name"]),
    "Pro" in pair[1]["name"]
), reverse=True)
print(choices[0][1]["name"], "on", choices[0][0].split(".")[-1], file=sys.stderr)
print(choices[0][1]["udid"])
')"
fi
xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
"$ROOT/scripts/fetch-models.sh"
(cd ios && xcodegen generate)
mkdir -p ios/build
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# Every shipped language must pass the full suite; UI tests catch untranslated or truncated strings.
# Italian runs in dark mode, so the screenshots show both appearances.
for run in en:US:light it:IT:dark; do
  IFS=: read -r LANGUAGE REGION APPEARANCE <<<"$run"
  xcrun simctl ui "$SIMULATOR_UDID" appearance "$APPEARANCE"
  RESULT="$ROOT/ios/build/TestResults-$LANGUAGE-$STAMP.xcresult"
  OUTPUT="$ROOT/ios/build/test-$LANGUAGE-$STAMP.log"
  run_tests() {
    rm -rf "$RESULT"
    xcodebuild test \
      -project ios/Oscuru.xcodeproj \
      -scheme Oscuru \
      -configuration Debug \
      -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
      -derivedDataPath "$ROOT/ios/DerivedData" \
      -resultBundlePath "$RESULT" \
      -testLanguage "$LANGUAGE" \
      -testRegion "$REGION" \
      CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$OUTPUT"
  }
  if ! run_tests; then
    # A test that failed has failed. A runner that never reached a test (the simulator can stall
    # while XCTest starts in it) says nothing about the app: start the simulator again and try once more.
    if grep -q "Test Case" "$OUTPUT"; then exit 1; fi
    echo "The test runner never started a test; restarting the simulator and trying once more." >&2
    xcrun simctl shutdown "$SIMULATOR_UDID" 2>/dev/null || true
    xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$SIMULATOR_UDID" -b
    xcrun simctl ui "$SIMULATOR_UDID" appearance "$APPEARANCE"
    run_tests
  fi
  printf '\nNative tests passed for %s_%s; Xcode result: %s\n' "$LANGUAGE" "$REGION" "$RESULT"
done
