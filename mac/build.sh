#!/bin/zsh
# Builds Voxa.app, signs it and installs it to ~/Applications. Run make-cert.sh once first.
set -e
cd "${0:A:h}"
KC="$PWD/signing/voxa-signing.keychain-db"
PASS=voxa-local-signing
# The Command Line Tools ship two module maps that both define SwiftBridging, which breaks every AppKit build.
# Deleting one needs admin, so this overlay hides it for our builds only.
FIX=(-Xcc -ivfsoverlay -Xcc "$PWD/toolchain-fix/overlay.yaml")

mkdir -p build
swiftc -swift-version 5 -O "${FIX[@]}" Sources/Voxa/*.swift -o build/Voxa
if [[ ! -f build/Voxa.icns || icon.swift -nt build/Voxa.icns ]]; then
  swiftc -O "${FIX[@]}" icon.swift -o build/make-icon
  ./build/make-icon build/Voxa.iconset
  iconutil -c icns build/Voxa.iconset -o build/Voxa.icns
fi

APP=build/Voxa.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Voxa "$APP/Contents/MacOS/Voxa"
cp Info.plist "$APP/Contents/Info.plist"
cp build/Voxa.icns "$APP/Contents/Resources/Voxa.icns"
security unlock-keychain -p "$PASS" "$KC"
# codesign finds identities only in the search list, whatever --keychain says, so the signing keychain joins it.
if ! security list-keychains -d user | grep -q voxa-signing; then
  security list-keychains -d user -s ~/Library/Keychains/login.keychain-db "$KC"
fi
codesign --force --keychain "$KC" -s "Voxa Self-Signed" "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/Voxa.app
ditto "$APP" ~/Applications/Voxa.app
touch ~/Applications/Voxa.app  # so Finder picks up the icon
codesign -dv ~/Applications/Voxa.app 2>&1 | grep -E 'Identifier|Authority'
