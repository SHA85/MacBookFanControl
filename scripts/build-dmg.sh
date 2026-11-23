#!/bin/bash
# Build MacBookFan and package it as a drag-to-install DMG.
#
#   ./scripts/build-dmg.sh
#
# Output: dist/MacBookFan-<version>.dmg (+ .sha256)
#
# Everything this script produces goes to build/ and dist/ at the project root — never inside the
# MacBookFan/ source folder, because Xcode copies every file in that folder into the app bundle.
#
# The app is not notarized, so on another Mac the first launch needs
# System Settings → Privacy & Security → Open Anyway. See the README in the DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT="MacBookFan"        # .xcodeproj name
TARGET="MacbookFan"         # scheme / product / executable name
HELPER_PLIST="macbook_fan.helper.plist"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
STAGE_DIR="$BUILD_DIR/dmg-stage"

echo "▸ Building $TARGET (Release)…"
xcodebuild \
  -project "$PROJECT.xcodeproj" \
  -scheme "$TARGET" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  -allowProvisioningUpdates \
  clean build | grep -E "error:|warning: |BUILD (SUCCEEDED|FAILED)" || true

APP="$BUILD_DIR/DerivedData/Build/Products/Release/$TARGET.app"
[ -d "$APP" ] || { echo "✗ Build failed: $APP not found"; exit 1; }

echo "▸ Checking the built app…"
[ -f "$APP/Contents/Library/LaunchDaemons/$HELPER_PLIST" ] \
  || { echo "✗ Fan control helper ($HELPER_PLIST) is missing from the app"; exit 1; }
HELPER_PROGRAM=$(/usr/libexec/PlistBuddy -c "Print :BundleProgram" "$APP/Contents/Library/LaunchDaemons/$HELPER_PLIST")
[ -x "$APP/$HELPER_PROGRAM" ] \
  || { echo "✗ $HELPER_PLIST points to $HELPER_PROGRAM, which is not in the app"; exit 1; }
codesign --verify --deep --strict "$APP" \
  || { echo "✗ Code signature is invalid"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
echo "▸ $TARGET $VERSION ($BUILD_NUM) · $BUNDLE_ID · macOS $MIN_OS+ · $(lipo -archs "$APP/Contents/MacOS/$TARGET")"

echo "▸ Preparing staging folder…"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$DIST_DIR"
ditto "$APP" "$STAGE_DIR/$TARGET.app"
ln -s /Applications "$STAGE_DIR/Applications"

cat > "$STAGE_DIR/README - How to Install.txt" <<EOF
MacBookFan $VERSION — fan control & thermal monitor for Apple Silicon Macs
Requires macOS $MIN_OS or later.

INSTALL
1. Drag $TARGET onto the Applications folder.
2. Open $TARGET from Applications.
3. The first time, macOS says it can't check the app for malicious software
   (the app is not notarized by Apple). Click "Done", then:
   System Settings → Privacy & Security → scroll down → "Open Anyway" next to
   $TARGET → confirm with your password or Touch ID.
   You only need to do this once.

FAN CONTROL
- Click "Enable Fan Control" in the menu bar menu, then turn on the app in
  System Settings → General → Login Items & Extensions → Allow in the Background.
- Do not run the app with sudo — it would disappear from the menu bar.

UNINSTALL
Quit the app, then move /Applications/$TARGET.app to the Trash.

────────────────────────────────────────

MacBookFan $VERSION — Apple Silicon Mac အတွက် fan ထိန်းချုပ်ခြင်းနဲ့ အပူချိန် စောင့်ကြည့်ခြင်း
macOS $MIN_OS နဲ့ အထက် လိုပါတယ်။

Install လုပ်နည်း
၁။ $TARGET ကို Applications folder ပေါ်ကို ဆွဲထည့်ပါ။
၂။ Applications ကနေ $TARGET ကို ဖွင့်ပါ။
၃။ ပထမဆုံးအကြိမ်မှာ macOS က app ကို စစ်ဆေးလို့မရဘူးလို့ ပြပါမယ်
   (Apple notarize မလုပ်ထားလို့ပါ)။ "Done" ကို နှိပ်ပြီး
   System Settings → Privacy & Security → အောက်ဆုံးနားမှာ $TARGET ဘေးက
   "Open Anyway" ကို နှိပ်ပါ → password ဒါမှမဟုတ် Touch ID နဲ့ အတည်ပြုပါ။
   ဒါကို တစ်ခါပဲ လုပ်ရပါတယ်။

Fan ထိန်းချုပ်ခြင်း
- Menu bar menu ထဲက "Enable Fan Control" ကို နှိပ်ပြီး
  System Settings → General → Login Items & Extensions → Allow in the Background
  မှာ app ကို ဖွင့်ပေးပါ။
- sudo နဲ့ မ run ပါနဲ့ — menu bar ကနေ ပျောက်သွားပါမယ်။

ဖြုတ်နည်း
App ကို Quit လုပ်ပြီး /Applications/$TARGET.app ကို Trash ထဲ ထည့်ပါ။
EOF

DMG="$DIST_DIR/$PROJECT-$VERSION.dmg"
echo "▸ Creating $DMG…"
rm -f "$DMG"
hdiutil create \
  -volname "$PROJECT $VERSION" \
  -srcfolder "$STAGE_DIR" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov "$DMG" >/dev/null

( cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

echo "✓ Done"
echo "  $DMG ($(du -h "$DMG" | cut -f1))"
echo "  SHA-256: $(cut -d' ' -f1 "$DMG.sha256")"
