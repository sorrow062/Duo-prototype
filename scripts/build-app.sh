#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}/.."
cd "$ROOT_DIR"

xcodebuild \
  -project "$ROOT_DIR/DuoPrototype.xcodeproj" \
  -scheme DuoPrototype \
  -configuration Release \
  -derivedDataPath "$ROOT_DIR/.build/xcode" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

APP_DIR="$ROOT_DIR/.build/DuoPrototype.app"
STAGED_APP="/private/tmp/DuoPrototype-build-$$.app"
rm -rf "$STAGED_APP"
ditto --norsrc "$ROOT_DIR/.build/xcode/Build/Products/Release/DuoPrototype.app" "$STAGED_APP"
find "$STAGED_APP" -print0 | xargs -0 -n1 xattr -c 2>/dev/null || true
WIDGET_DIR="$STAGED_APP/Contents/PlugIns/DuoWidget.appex"
codesign --force --sign - --entitlements "$ROOT_DIR/Resources/DuoWidget.entitlements" "$WIDGET_DIR" >/dev/null
# Signing can restore Finder metadata on the nested bundle; remove it before
# signing and verifying the containing application.
find "$STAGED_APP" -print0 | xargs -0 -n1 xattr -c 2>/dev/null || true
codesign --force --sign - "$STAGED_APP" >/dev/null
for package in "$STAGED_APP" "$WIDGET_DIR"; do
  xattr -d com.apple.FinderInfo "$package" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$package" 2>/dev/null || true
done
codesign --verify --strict "$WIDGET_DIR"
codesign --verify --deep --strict "$STAGED_APP"
rm -rf "$APP_DIR"
ditto --norsrc "$STAGED_APP" "$APP_DIR"
rm -rf "$STAGED_APP"

echo "Built $APP_DIR with WidgetKit extension"
