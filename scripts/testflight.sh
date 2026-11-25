#!/usr/bin/env bash
# Builds, signs and uploads Oscuru to TestFlight. GitHub-hosted macOS only.
#
# Needs: APPLE_DISTRIBUTION_P12_BASE64, APPLE_DISTRIBUTION_P12_PASSWORD (the team's distribution
# certificate), ASC_PRIVATE_KEY_BASE64, ASC_KEY_ID, ASC_ISSUER_ID (an App Store Connect API key with
# the Admin role) and TEAM_ID. The bundle ID, provisioning profile, build number and TestFlight
# group are handled through the App Store Connect API (scripts/asc.py). Prints no secrets.
set +x
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(uname -s)" == Darwin && -d "${RUNNER_TEMP:-}" ]] || { echo 'Run this on a GitHub-hosted macOS runner.' >&2; exit 1; }
for name in APPLE_DISTRIBUTION_P12_BASE64 APPLE_DISTRIBUTION_P12_PASSWORD ASC_PRIVATE_KEY_BASE64 ASC_KEY_ID ASC_ISSUER_ID TEAM_ID; do
  [[ -n "${!name:-}" ]] || { echo "Missing $name." >&2; exit 1; }
done

WORK="$(mktemp -d "$RUNNER_TEMP/oscuru-testflight.XXXXXX")"
KEYCHAIN="$WORK/signing.keychain-db"
SIGNING_XCCONFIG="$ROOT/ios/Config/Signing.local.xcconfig"
ORIGINAL_KEYCHAINS="$(security list-keychains -d user | tr -d '"' | xargs)"
STAGE='starting'
cleanup() {
  status=$?
  security list-keychains -d user -s $ORIGINAL_KEYCHAINS >/dev/null 2>&1 || true
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  for uuid in "${PROFILE_UUID:-}" "${PROFILE_UUID_CAPTURE:-}" "${PROFILE_UUID_CONTROLS:-}"; do
    [[ -z "$uuid" ]] || rm -f "$HOME/Library/MobileDevice/Provisioning Profiles/$uuid.mobileprovision"
  done
  rm -f "$SIGNING_XCCONFIG"
  rm -rf "$WORK"
  [[ $status == 0 ]] || echo "Failed while $STAGE (exit $status)." >&2
  exit $status
}
trap cleanup EXIT

STAGE='decoding the signing files'
mkdir "$WORK/private_keys"
printf '%s' "$ASC_PRIVATE_KEY_BASE64" | base64 --decode > "$WORK/private_keys/AuthKey_$ASC_KEY_ID.p8"
printf '%s' "$APPLE_DISTRIBUTION_P12_BASE64" | base64 --decode > "$WORK/distribution.p12"
unset ASC_PRIVATE_KEY_BASE64 APPLE_DISTRIBUTION_P12_BASE64
export ASC_KEY_PATH="$WORK/private_keys/AuthKey_$ASC_KEY_ID.p8"
export P12_PASSWORD="$APPLE_DISTRIBUTION_P12_PASSWORD"
unset APPLE_DISTRIBUTION_P12_PASSWORD

STAGE='reading the certificate serial number'
# macOS's own openssl (LibreSSL) reads the older .p12 encryption that OpenSSL 3 rejects.
SERIAL="$(/usr/bin/openssl pkcs12 -in "$WORK/distribution.p12" -nokeys -passin env:P12_PASSWORD 2>/dev/null |
  /usr/bin/openssl x509 -noout -serial | cut -d= -f2)"
[[ -n "$SERIAL" ]] || { echo 'Could not read the certificate in the .p12.' >&2; exit 1; }

STAGE='talking to App Store Connect'
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install --quiet --disable-pip-version-check pyjwt cryptography
"$WORK/venv/bin/python" "$ROOT/scripts/asc.py" prepare "$WORK" "$SERIAL"
# shellcheck disable=SC1091
source "$WORK/asc.env"

STAGE='installing the certificate and profile'
security create-keychain -p "" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "" "$KEYCHAIN"
security import "$WORK/distribution.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -t cert -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security >/dev/null
unset P12_PASSWORD
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $ORIGINAL_KEYCHAINS
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/Apple Distribution|iPhone Distribution/ { print $2; exit }')"
[[ -n "$IDENTITY" ]] || { echo 'No distribution identity in the .p12.' >&2; exit 1; }
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
# The app, its Lock Screen camera extension and its controls extension each have their own profile.
cp "$WORK/profile.mobileprovision" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
cp "$WORK/profile-capture.mobileprovision" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID_CAPTURE.mobileprovision"
cp "$WORK/profile-controls.mobileprovision" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID_CONTROLS.mobileprovision"

STAGE='archiving'
# Signing settings reach the app and extension targets only (see ios/Config/Oscuru.xcconfig).
printf '%s\n' \
  'OSCURU_CODE_SIGN_STYLE = Manual' \
  "OSCURU_DEVELOPMENT_TEAM = $TEAM_ID" \
  "OSCURU_PROVISIONING_PROFILE = $PROFILE_UUID" \
  "OSCURU_CAPTURE_PROVISIONING_PROFILE = $PROFILE_UUID_CAPTURE" \
  "OSCURU_CONTROLS_PROVISIONING_PROFILE = $PROFILE_UUID_CONTROLS" \
  "OSCURU_CODE_SIGN_IDENTITY = $IDENTITY" \
  "CURRENT_PROJECT_VERSION = $BUILD_NUMBER" > "$SIGNING_XCCONFIG"
"$ROOT/scripts/fetch-models.sh"
(cd "$ROOT/ios" && xcodegen generate >/dev/null)
if ! xcodebuild archive -project "$ROOT/ios/Oscuru.xcodeproj" -scheme Oscuru -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$WORK/Oscuru.xcarchive" -derivedDataPath "$WORK/DerivedData" \
  > "$WORK/archive.log" 2>&1; then
  grep -E 'error:|Signing|provision' "$WORK/archive.log" | sort -u | head -40 >&2
  exit 1
fi

STAGE='exporting the IPA'
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$IDENTITY</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>com.rudilosso.oscuru</key><string>$PROFILE_UUID</string>
    <key>com.rudilosso.oscuru.capture</key><string>$PROFILE_UUID_CAPTURE</string>
    <key>com.rudilosso.oscuru.controls</key><string>$PROFILE_UUID_CONTROLS</string>
  </dict>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
if ! xcodebuild -exportArchive -archivePath "$WORK/Oscuru.xcarchive" -exportPath "$WORK/export" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" > "$WORK/export.log" 2>&1; then
  grep -E 'error|Error' "$WORK/export.log" | sort -u | head -40 >&2
  exit 1
fi
IPA="$(ls "$WORK"/export/*.ipa)"

STAGE='uploading to App Store Connect'
xcrun altool --help > "$WORK/altool-help.txt" 2>&1 || true
if grep -q -- '--api-key' "$WORK/altool-help.txt"; then
  AUTH=(--api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID")
else
  AUTH=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")
fi
# altool finds the key in ./private_keys.
if ! (cd "$WORK" && xcrun altool --upload-app -f "$IPA" -t ios "${AUTH[@]}" > "$WORK/upload.log" 2>&1); then
  grep -vE '^\s*$' "$WORK/upload.log" | tail -30 >&2
  exit 1
fi
echo "::notice::Uploaded Oscuru build $BUILD_NUMBER. It appears in TestFlight once Apple has processed it (usually 5–30 minutes)."

STAGE='setting up TestFlight testers'
"$WORK/venv/bin/python" "$ROOT/scripts/asc.py" testers "$APP_ID"
STAGE='done'
