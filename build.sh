#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcrun >/dev/null 2>&1; then
  echo 'Apple developer tools not found. Run: xcode-select --install' >&2
  exit 1
fi
APP="$PWD/dist/Velo.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns Resources/MenuBarTemplate*.png "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
echo 'Compiling native macOS application...'
xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/Velo-ModuleCache" -target "$(uname -m)-apple-macosx13.0" -O -framework AppKit -framework AVFoundation -framework Speech \
  -framework Carbon -framework ApplicationServices \
  Sources/*.swift -o "$APP/Contents/MacOS/Velo"
chmod +x "$APP/Contents/MacOS/Velo"
# Use an existing identity without creating certificates or resetting permissions.
IDENTITY="${VELO_SIGNING_IDENTITY:-BreezeDictate Local Signing}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1 && codesign --force --sign "$IDENTITY" "$APP"; then
  echo "Signed with existing identity: $IDENTITY"
else
  echo 'Using ad-hoc signing; Accessibility may need reauthorization after rebuilding.'
  codesign --force --sign - "$APP"
fi
echo ''
echo "Built: $APP"
echo 'Start with: open "dist/Velo.app"'
