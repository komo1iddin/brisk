#!/usr/bin/env bash
# Distribution only: run in an ephemeral release runner after license review.
# This uploads the built app to Apple's notary service.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
app="${1:?usage: sign-native.sh /path/ZapFast.app /path/output.zip}"
output="${2:?output zip required}"
python3 "$root/macos/Scripts/check-release-license.py"
python3 "$root/macos/Scripts/check-native-bundle.py" "$app"
for variable in MAC_CERTIFICATE_P12 MAC_CERTIFICATE_PASSWORD MAC_SIGN_IDENTITY APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    test -n "${!variable:-}" || { echo "Missing release credential: $variable" >&2; exit 1; }
done
case "$MAC_SIGN_IDENTITY" in
    'Developer ID Application: '*) ;;
    *) echo "A Developer ID Application identity is required." >&2; exit 1 ;;
esac
work="$(mktemp -d)"
sign_keychain="$work/native-release.keychain-db"
sign_password="$(uuidgen)"
cleanup() {
    security delete-keychain "$sign_keychain" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
printf '%s' "$MAC_CERTIFICATE_P12" | base64 --decode > "$work/certificate.p12"
security create-keychain -p "$sign_password" "$sign_keychain"
security set-keychain-settings -lut 21600 "$sign_keychain"
security unlock-keychain -p "$sign_password" "$sign_keychain"
security import "$work/certificate.p12" -k "$sign_keychain" -P "$MAC_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$sign_password" "$sign_keychain" >/dev/null
sign() {
    codesign --force --timestamp --options runtime --keychain "$sign_keychain" --sign "$MAC_SIGN_IDENTITY" "$@"
}
if [[ -d "$app/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' library; do sign "$library"; done < <(find "$app/Contents/Frameworks" -type f -name '*.dylib' -print0)
    while IFS= read -r -d '' framework; do sign "$framework"; done < <(find "$app/Contents/Frameworks" -depth -type d -name '*.framework' -print0)
fi
sign --entitlements "$root/macos/ShareExtension/ZapFastShare.entitlements" "$app/Contents/PlugIns/ZapFastShare.appex"
sign --entitlements "$root/macos/App/ZapFast.entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dvv "$app" 2> "$work/signature.txt"
grep -q '^Authority=Developer ID Application:' "$work/signature.txt"
grep -Fxq "TeamIdentifier=$APPLE_TEAM_ID" "$work/signature.txt"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/submission.zip"
xcrun notarytool submit "$work/submission.zip" --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
    --wait --timeout 30m --output-format json > "$work/notary-result.json"
python3 - "$work/notary-result.json" <<'PY'
import json, sys
if json.load(open(sys.argv[1])).get('status') != 'Accepted':
    raise SystemExit('Apple did not accept the notarization submission.')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
mkdir -p "$(dirname "$output")"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output"
echo "Developer ID signature, notarization and stapled native package verified."
