#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache"
BIN_DIR=$(swift build -c release --show-bin-path)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
CHANNEL=$(/usr/libexec/PlistBuddy -c 'Print :VMMReleaseChannel' Resources/Info.plist 2>/dev/null || true)
SUFFIX=""
if [[ "$CHANNEL" == "beta" ]]; then SUFFIX="-beta1"; fi
APP="${1:-$PWD/dist/VMM-$VERSION$SUFFIX.app}"
if [[ -e "$APP" ]]; then
  echo "Existing app preserved: $APP. Pass a new destination path." >&2
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VMM" "$APP/Contents/MacOS/VMM"
mkdir -p "$APP/Contents/Helpers"
cp "$BIN_DIR/VMMAnimationWorker" "$APP/Contents/Helpers/"
cp "$BIN_DIR/VMMMCPBridge" "$APP/Contents/Helpers/"
# Release executables can retain object-file paths containing the build user's
# home directory in debug symbols. Remove them before signing the distribution.
strip -S "$APP/Contents/MacOS/VMM" "$APP/Contents/Helpers/VMMMCPBridge" "$APP/Contents/Helpers/VMMAnimationWorker"
build_directory="$(pwd -P)"
for binary in "$APP/Contents/MacOS/VMM" "$APP/Contents/Helpers/VMMMCPBridge" "$APP/Contents/Helpers/VMMAnimationWorker"; do
  if { [[ -n "${HOME:-}" && "$HOME" != "/" ]] && LC_ALL=C grep -a -F -q -- "${HOME%/}/" "$binary"; } ||
     { [[ "$build_directory" != "/" ]] && LC_ALL=C grep -a -F -q -- "$build_directory/" "$binary"; }; then
    echo "Build paths remain in a distribution executable; refusing to sign it." >&2
    exit 1
  fi
done
codesign --force --sign - "$APP/Contents/Helpers/VMMMCPBridge"
codesign --force --sign - "$APP/Contents/Helpers/VMMAnimationWorker"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp scripts/qwen3_tts_bridge.py "$APP/Contents/Resources/"
cp docs/SPEECH-ENGINES.md "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/images"
cp docs/images/speech.png "$APP/Contents/Resources/images/"
cp LICENSE "$APP/Contents/Resources/LICENSE"
codesign --force --sign - "$APP"
echo "Built: $APP"
