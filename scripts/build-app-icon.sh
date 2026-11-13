#!/bin/zsh
# Regenerate the committed macOS icon from its PNG master using system tools.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
ICON_WORK=$(mktemp -d "$PWD/.build/app-icon-XXXXXXXX")
trap 'rm -rf "$ICON_WORK"' EXIT
ICON_SET="$ICON_WORK/AppIcon.iconset"
mkdir -p "$ICON_SET"
for ICON_SIZE in 16 32 128 256 512; do
  sips -z "$ICON_SIZE" "$ICON_SIZE" Resources/AppIcon.png --out "$ICON_SET/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
  ICON_RETINA=$(( ICON_SIZE * 2 ))
  sips -z "$ICON_RETINA" "$ICON_RETINA" Resources/AppIcon.png --out "$ICON_SET/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_SET" -o Resources/AppIcon.icns
print 'Generated Resources/AppIcon.icns'
