#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}/.."
cd "$ROOT_DIR"

strip_bundle_metadata() {
  local bundle="$1"
  # Launch Services and Finder can attach these attributes while a bundle is
  # copied. They invalidate ad-hoc signature verification on the final app.
  xattr -dr com.apple.provenance "$bundle" 2>/dev/null || true
  xattr -dr com.apple.FinderInfo "$bundle" 2>/dev/null || true
  xattr -dr 'com.apple.fileprovider.fpfs#P' "$bundle" 2>/dev/null || true
}

xcodebuild \
  -project "$ROOT_DIR/DuoPrototype.xcodeproj" \
  -scheme DuoPrototype \
  -configuration Release \
  -derivedDataPath "$ROOT_DIR/.build/xcode" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

APP_DIR="$ROOT_DIR/.build/DuoPrototype.app"
STAGING_DIR="/private/tmp/DuoPrototype-build-$$"
STAGED_APP="$STAGING_DIR/DuoPrototype.app"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto --norsrc "$ROOT_DIR/.build/xcode/Build/Products/Release/DuoPrototype.app" "$STAGED_APP"
find "$STAGED_APP" -print0 | xargs -0 -n1 xattr -c 2>/dev/null || true
WIDGET_DIR="$STAGED_APP/Contents/PlugIns/DuoWidget.appex"
codesign --force --sign - --entitlements "$ROOT_DIR/Resources/DuoWidget.entitlements" "$WIDGET_DIR" >/dev/null
# Xcode removes development headers when embedding Sparkle's pre-signed
# framework, which invalidates its original resource seal. Re-sign the embedded
# framework locally before signing the containing app.
for framework in "$STAGED_APP"/Contents/Frameworks/*.framework; do
  [[ -d "$framework" ]] || continue
  codesign --force --sign - "$framework" >/dev/null
done
# Signing can restore Finder metadata on the nested bundle; remove it before
# signing and verifying the containing application.
find "$STAGED_APP" -print0 | xargs -0 -n1 xattr -c 2>/dev/null || true
codesign --force --sign - "$STAGED_APP" >/dev/null
for package in "$STAGED_APP" "$WIDGET_DIR"; do
  xattr -d com.apple.FinderInfo "$package" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$package" 2>/dev/null || true
done
# codesign may restore Finder metadata on nested Sparkle XPC bundles. Remove
# all extended attributes recursively so Launch Services can open the final app.
xattr -rc "$STAGED_APP" 2>/dev/null || true
strip_bundle_metadata "$STAGED_APP"
codesign --verify --strict "$WIDGET_DIR"
codesign --verify --deep --strict "$STAGED_APP"

if [[ "${PACKAGE_APP:-0}" == "1" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")
  ARCHIVE="$ROOT_DIR/outputs/DuoPrototype-${VERSION}-macOS-arm64.zip"
  mkdir -p "$ROOT_DIR/outputs"
  ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$ARCHIVE"
  echo "Packaged $ARCHIVE"
fi

rm -rf "$APP_DIR"
ditto --norsrc "$STAGED_APP" "$APP_DIR"
xattr -rc "$APP_DIR" 2>/dev/null || true
strip_bundle_metadata "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
rm -rf "$STAGING_DIR"

echo "Built $APP_DIR with WidgetKit extension"
