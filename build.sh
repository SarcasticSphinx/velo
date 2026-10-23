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
# macOS ties Accessibility permission to the signature. An ad-hoc signature changes on
# every build, silently revoking auto-paste, so sign with a stable local certificate.
IDENTITY="BreezeDictate Local Signing"
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "Creating local code-signing certificate \"$IDENTITY\" (one time)..."
  CERTDIR=$(mktemp -d -t breezecert)
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$IDENTITY" \
    -keyout "$CERTDIR/key.pem" -out "$CERTDIR/cert.pem" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
  LEGACY=$(openssl version | grep -q '^OpenSSL 3' && echo -legacy || true)
  openssl pkcs12 -export $LEGACY -inkey "$CERTDIR/key.pem" -in "$CERTDIR/cert.pem" \
    -name "$IDENTITY" -out "$CERTDIR/identity.p12" -passout pass:breeze
  security import "$CERTDIR/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P breeze -T /usr/bin/codesign >/dev/null
  rm -rf "$CERTDIR"
fi
if codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
  # Permission granted to a previous ad-hoc build can't carry over; reset it once so macOS asks again.
  MARKER="$PWD/dist/.signed-with-local-certificate"
  if [ ! -f "$MARKER" ]; then
    tccutil reset Accessibility dev.local.BreezeDictate >/dev/null 2>&1 || true
    touch "$MARKER"
    echo 'Re-enable Accessibility for Velo when prompted (needed once).'
  fi
else
  echo 'Local certificate unavailable; using ad-hoc signature (Accessibility must be re-enabled after each build).'
  codesign --force --sign - "$APP"
fi
echo ''
echo "Built: $APP"
echo 'Start with: open "dist/Velo.app"'
