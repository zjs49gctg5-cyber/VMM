#!/bin/zsh
# Work on a UUID-named copy. Never modifies the source app or previous releases.
set -euo pipefail
usage() {
  cat <<'EOF'
Usage: scripts/sign-notarize.sh --app APP --identity 'Developer ID Application: NAME (TEAM)' --profile KEYCHAIN_PROFILE [--output-dir DIR] [--dry-run]
The real run signs a copy, uploads it to Apple, staples the accepted ticket,
and creates a distributable ZIP. Credentials must already be in Keychain.
EOF
}
APP_SOURCE=""; SIGN_IDENTITY=""; NOTARY_PROFILE=""; OUTPUT_DIR=""; DRY_RUN=0
while (( $# )); do
  case "$1" in
    --app|--identity|--profile|--output-dir)
      (( $# >= 2 )) || { usage >&2; exit 2; }
      case "$1" in
        --app) APP_SOURCE="$2" ;;
        --identity) SIGN_IDENTITY="$2" ;;
        --profile) NOTARY_PROFILE="$2" ;;
        --output-dir) OUTPUT_DIR="$2" ;;
      esac
      shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -d "$APP_SOURCE/Contents/MacOS" && -f "$APP_SOURCE/Contents/Info.plist" ]] || { print -u2 'Specify an existing app bundle.'; exit 2; }
[[ "$SIGN_IDENTITY" == 'Developer ID Application: '* && -n "$NOTARY_PROFILE" ]] || { print -u2 'Developer ID Application identity and Keychain profile are required.'; exit 2; }
APP_SOURCE="${APP_SOURCE:A}"
[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="${APP_SOURCE:h}"
[[ "${OUTPUT_DIR:A}" != "$APP_SOURCE" && "${OUTPUT_DIR:A}" != "$APP_SOURCE/"* ]] || { print -u2 'Output directory must be outside the source app.'; exit 2; }
if (( DRY_RUN )); then
  print 'Dry run: no files, signatures, Keychain access or uploads.'
  print '1. Create a UUID release folder and copy the app.'
  print '2. Sign the JavaScript and MCP helpers (when present), VMM and its bundle with hardened runtime and secure timestamp.'
  print '3. Verify signatures and submit ZIP using the Keychain profile.'
  print '4. Require Accepted status, staple, validate and assess Gatekeeper.'
  print '5. Create final ZIP containing the stapled app; preserve logs.'
  exit 0
fi
/usr/bin/xcrun --find notarytool >/dev/null
/usr/bin/xcrun --find stapler >/dev/null
# Fail before copying if the bundle structure has changed. Additional nested code
# requires explicit inside-out signing, rather than blindly using --deep to sign.
[[ -f "$APP_SOURCE/Contents/MacOS/VMM" ]] || { print -u2 'VMM executable is missing.'; exit 2; }
NESTED_CODE=$(/usr/bin/find "$APP_SOURCE/Contents" \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' -o -name '*.app' \) -print)
[[ -z "$NESTED_CODE" ]] || { print -u2 'Nested code found. Add explicit inside-out signing before distributing this bundle.'; exit 2; }
mkdir -p "$OUTPUT_DIR"
RELEASE_DIR=$(mktemp -d "$OUTPUT_DIR/VMM-release-XXXXXXXX")
SIGNED_APP="$RELEASE_DIR/${APP_SOURCE:t}"
/usr/bin/ditto "$APP_SOURCE" "$SIGNED_APP"
if [[ -d "$SIGNED_APP/Contents/Helpers" ]]; then
  for HELPER in "$SIGNED_APP/Contents/Helpers/"*; do
    case "${HELPER:t}" in
      VMMAnimationWorker|VMMMCPBridge)
        [[ -f "$HELPER" && ! -L "$HELPER" ]] || { print -u2 'Unexpected helper structure.'; exit 2; }
        /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$HELPER" ;;
      *) print -u2 'Unexpected helper code. Add explicit signing for it before distributing.'; exit 2 ;;
    esac
  done
fi
/usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SIGNED_APP/Contents/MacOS/VMM"
/usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SIGNED_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$SIGNED_APP"
UPLOAD_ZIP="$RELEASE_DIR/submission.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$SIGNED_APP" "$UPLOAD_ZIP"
# Output is saved even when notarytool reports rejection. Nothing is distributed then.
SUBMIT_EXIT=0
/usr/bin/xcrun notarytool submit "$UPLOAD_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist > "$RELEASE_DIR/notary-result.plist" 2> "$RELEASE_DIR/notary-stderr.txt" || SUBMIT_EXIT=$?
NOTARY_STATUS=$(/usr/libexec/PlistBuddy -c 'Print :status' "$RELEASE_DIR/notary-result.plist" 2>/dev/null || true)
REQUEST_ID=$(/usr/libexec/PlistBuddy -c 'Print :id' "$RELEASE_DIR/notary-result.plist" 2>/dev/null || true)
[[ -z "$REQUEST_ID" ]] || /usr/bin/xcrun notarytool log "$REQUEST_ID" --keychain-profile "$NOTARY_PROFILE" "$RELEASE_DIR/notary-log.json" || print -u2 'Could not retrieve notary log; result plist is preserved.'
[[ "$NOTARY_STATUS" == Accepted && "$SUBMIT_EXIT" == 0 ]] || { print -u2 "Notarization was not accepted. See $RELEASE_DIR"; exit 1; }
/usr/bin/xcrun stapler staple "$SIGNED_APP"
/usr/bin/xcrun stapler validate "$SIGNED_APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$SIGNED_APP"
FINAL_ZIP="$RELEASE_DIR/${APP_SOURCE:t:r}-notarized.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$SIGNED_APP" "$FINAL_ZIP"
print "Signed and notarized app: $SIGNED_APP"
print "Distribution archive: $FINAL_ZIP"
