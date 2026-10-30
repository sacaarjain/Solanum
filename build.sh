#!/bin/bash
# Builds Solanum.app from source and installs it to ~/Applications.
#   ./build.sh            release build + install
#   ./build.sh --debug    debug build + install
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Solanum"
BUNDLE_ID="local.solanum.terminal"
# 0.1.<commits on this branch>: every commit pushed to main moves the version up, with nothing to bump by hand.
VERSION="0.1.$(git rev-list --count HEAD 2>/dev/null || echo 0)"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

OPT="-O"; MODE="release"
[[ "${1:-}" == "--debug" ]] && { OPT="-Onone -g"; MODE="debug"; }

fail() { echo "✗ $*" >&2; exit 1; }

# Checked up front, so a Mac that can't build Solanum says why and what to do, not a compiler or linker error.
MACOS="$(sw_vers -productVersion)"
(( ${MACOS%%.*} >= 14 )) || fail "Solanum needs macOS 14 (Sonoma) or later; this Mac has $MACOS."
if ! SWIFT="$(swiftc -version 2>&1)"; then
  echo "$SWIFT" >&2
  case "$SWIFT" in
    *license*) fail "Accept the Xcode license first: sudo xcodebuild -license accept" ;;
    *"developer path"*) fail "The selected developer tools are missing. Run xcode-select --install (or sudo xcode-select --reset if Xcode is installed)." ;;
    *) fail "No working Swift compiler. Install the Command Line Tools with xcode-select --install, or Xcode." ;;
  esac
fi
SDK="$(xcrun --show-sdk-version 2>/dev/null || echo 0)"
(( ${SDK%%.*} >= 14 )) || fail "The macOS SDK ($SDK) is older than 14. Update the Command Line Tools (System Settings › Software Update) or Xcode."
# This Mac's own architecture, also from a Rosetta shell (where uname -m says x86_64 on Apple silicon).
if [[ -n "${SOLANUM_ARCH:-}" ]]; then ARCH="$SOLANUM_ARCH"
elif [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == 1 ]]; then ARCH="arm64"
else ARCH="x86_64"; fi
echo "› $(grep -m1 -o 'Swift version [^ ]*' <<<"$SWIFT" || echo Swift), macOS $SDK SDK, $ARCH"

mkdir -p "$BUILD_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Incremental and parallel: objects are kept per mode and architecture in build/obj-<mode>-<arch>, so a rebuild only
# recompiles the files that changed (and those depending on what changed), across all cores. Not whole-module: that's
# one job on one core.
OBJ="$BUILD_DIR/obj-$MODE-$ARCH"
mkdir -p "$OBJ"
{
  printf '{"": {"swift-dependencies": "%s/master.swiftdeps"}' "$OBJ"
  for f in Sources/*.swift; do
    b="$(basename "$f" .swift)"
    printf ',\n"%s": {"object": "%s/%s.o", "swift-dependencies": "%s/%s.swiftdeps"}' "$f" "$OBJ" "$b" "$OBJ" "$b"
  done
  echo '}'
} > "$OBJ/output-file-map.json"

echo "› Compiling…"
swiftc $OPT -swift-version 5 \
  -incremental -enable-batch-mode -j"$(sysctl -n hw.ncpu)" -output-file-map "$OBJ/output-file-map.json" \
  -target "$ARCH-apple-macosx14.0" \
  -import-objc-header Support/Bridging.h \
  -framework AppKit -framework Carbon -framework UserNotifications -framework AVKit -framework PDFKit -framework WebKit \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME" 2>&1 | grep -v -E "^(.*warning:|\s*[0-9]*\s*\||\s*$|.*note:)" || true
[[ -x "$APP/Contents/MacOS/$APP_NAME" ]] || fail "Build failed (the compiler's errors are above)."

# The icon is drawn by a small tool. Without it Solanum still works, with the generic app icon, so a problem here
# doesn't stop the install.
echo "› Generating icon…"
if [[ ! -f "$BUILD_DIR/AppIcon.icns" || Tools/MakeIcon.swift -nt "$BUILD_DIR/AppIcon.icns" || Sources/SolanumArt.swift -nt "$BUILD_DIR/AppIcon.icns" ]]; then
  rm -rf "$BUILD_DIR/AppIcon.iconset" "$BUILD_DIR/AppIcon.icns"
  if ! { swiftc -O -target "$ARCH-apple-macosx14.0" -parse-as-library Tools/MakeIcon.swift Sources/SolanumArt.swift \
           -o "$BUILD_DIR/makeicon" >"$BUILD_DIR/makeicon.log" 2>&1 &&
         "$BUILD_DIR/makeicon" "$BUILD_DIR/AppIcon.iconset" >>"$BUILD_DIR/makeicon.log" 2>&1 &&
         iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns" >>"$BUILD_DIR/makeicon.log" 2>&1; }; then
    rm -f "$BUILD_DIR/AppIcon.icns"
    echo "  Couldn't make the icon, so Solanum gets the generic one (details in $BUILD_DIR/makeicon.log)."
  fi
fi
[[ -f "$BUILD_DIR/AppIcon.icns" ]] && cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp Support/Bells.svg Support/Solanum.svg Support/QuantumMoon.png Support/Fonts/SpaceMono-Regular.ttf "$APP/Contents/Resources/"

# Where this build came from, for Solanum's update check (Sources/Updater.swift): the repository (the main
# checkout, also when building in a worktree) and the commit.
REPO=""; COMMIT=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  REPO="$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
  COMMIT="$(git rev-parse HEAD)"
fi
# Escaped for the plist, so a folder named like "R&D" doesn't break it.
xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

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
  <key>SolanumRepo</key><string>$(xml "$REPO")</string>
  <key>SolanumCommit</key><string>$COMMIT</string>
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
plutil -lint -s "$APP/Contents/Info.plist" || fail "The generated Info.plist is invalid."

# A stable identity keeps macOS privacy grants (Full Disk Access, folders) across rebuilds;
# ad-hoc signatures change every build, so TCC forgets them. Set SOLANUM_SIGN_ID to use a different certificate.
# A certificate that can't sign (no private key, expired, a locked keychain during an update) falls back to ad-hoc.
SIGN_ID="${SOLANUM_SIGN_ID:-Solanum Local}"
SIGNED=""
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_ID\""; then
  echo "› Signing ($SIGN_ID)…"
  if codesign --force --deep -s "$SIGN_ID" "$APP"; then SIGNED=1
  else echo "  Couldn't sign with \"$SIGN_ID\"; signing ad-hoc instead (macOS may ask again for permissions)."; fi
else
  echo "› Signing (ad-hoc; create a \"$SIGN_ID\" code-signing cert to keep permissions across rebuilds)…"
fi
if [[ -z "$SIGNED" ]]; then
  OUT="$(codesign --force --deep -s - "$APP" 2>&1)" || { echo "$OUT" >&2; fail "Couldn't sign the app."; }
fi

# Copied in beside the old copy and then swapped with it, so a failed copy (a full disk) never leaves no Solanum at all.
echo "› Installing to ${INSTALL_DIR}…"
mkdir -p "$INSTALL_DIR"
NEW="$INSTALL_DIR/.$APP_NAME.app.new"; OLD="$INSTALL_DIR/.$APP_NAME.app.old"
rm -rf "$NEW" "$OLD"
cp -R "$APP" "$NEW"
[[ -e "$INSTALL_DIR/$APP_NAME.app" ]] && mv "$INSTALL_DIR/$APP_NAME.app" "$OLD"
mv "$NEW" "$INSTALL_DIR/$APP_NAME.app"
rm -rf "$OLD"
# Only the installed copy is Solanum to macOS: a registered build/ copy can be launched beside it (a second Solanum).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
echo "✓ Installed $INSTALL_DIR/$APP_NAME.app"
