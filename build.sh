#!/bin/bash
# Builds Solanum.app from source and installs it to ~/Applications.
#   ./build.sh            release build + install
#   ./build.sh --debug    debug build + install
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Solanum"
BUNDLE_ID="local.solanum.terminal"
VERSION="0.1.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

OPT="-O"
[[ "${1:-}" == "--debug" ]] && OPT="-Onone -g"

mkdir -p "$BUILD_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "› Compiling…"
swiftc $OPT -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -import-objc-header Support/Bridging.h \
  -framework AppKit -framework Carbon -framework UserNotifications -framework AVKit -framework PDFKit -framework WebKit \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME" 2>&1 | grep -v -E "^(.*warning:|\s*\||\s*$|.*note:)" || true
[[ -x "$APP/Contents/MacOS/$APP_NAME" ]] || { echo "Build failed"; exit 1; }

echo "› Generating icon…"
if [[ ! -f "$BUILD_DIR/AppIcon.icns" || Tools/MakeIcon.swift -nt "$BUILD_DIR/AppIcon.icns" || Sources/SolanumArt.swift -nt "$BUILD_DIR/AppIcon.icns" ]]; then
  rm -rf "$BUILD_DIR/AppIcon.iconset"
  swiftc -O -parse-as-library Tools/MakeIcon.swift Sources/SolanumArt.swift -o "$BUILD_DIR/makeicon" 2>/dev/null
  "$BUILD_DIR/makeicon" "$BUILD_DIR/AppIcon.iconset"
  iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"
fi
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <!-- Listed under Finder's Open With for text files (Alternate rank: never made the default app). -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Text</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.text</string><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# A stable identity keeps macOS privacy grants (Full Disk Access, folders) across rebuilds;
# ad-hoc signatures change every build, so TCC forgets them. Set SOLANUM_SIGN_ID to use a different certificate.
SIGN_ID="${SOLANUM_SIGN_ID:-Solanum Local}"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  echo "› Signing ($SIGN_ID)…"
  codesign --force --deep -s "$SIGN_ID" "$APP"
else
  echo "› Signing (ad-hoc; create a \"$SIGN_ID\" code-signing cert to keep permissions across rebuilds)…"
  codesign --force --deep -s - "$APP" >/dev/null 2>&1
fi

echo "› Installing to ${INSTALL_DIR}…"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"
echo "✓ Installed $INSTALL_DIR/$APP_NAME.app"
