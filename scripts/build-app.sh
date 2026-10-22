#!/bin/zsh
# macOS runs this file with zsh (the shebang, and the default shell). Reset to
# stock zsh semantics so an interactive ~/.zshrc cannot change globbing, then
# turn the usual safety options back on. In zsh, "(" is a pattern
# metacharacter even by default and must be quoted inside ${var%pattern}.
emulate -R zsh
set -euo pipefail

ROOT_DIR="${0:A:h}/.."
cd "$ROOT_DIR"

APP_DIR="$ROOT_DIR/.build/DuoPrototype.app"
STAGING_DIR="/private/tmp/DuoPrototype-build-$$"
STAGED_APP="$STAGING_DIR/DuoPrototype.app"

strip_bundle_metadata() {
  local bundle="$1"
  # Launch Services and Finder can attach these attributes while a bundle is
  # copied. They invalidate ad-hoc signature verification on the final app.
  xattr -dr com.apple.provenance "$bundle" 2>/dev/null || true
  xattr -dr com.apple.FinderInfo "$bundle" 2>/dev/null || true
  xattr -dr 'com.apple.fileprovider.fpfs#P' "$bundle" 2>/dev/null || true
}

# Full Xcode provides usr/bin/xcodebuild inside the selected developer
# directory. Command Line Tools leave xcode-select pointed at
# /Library/Developer/CommandLineTools, where /usr/bin/xcodebuild only prints
# "tool 'xcodebuild' requires Xcode".
xcodebuild_is_usable() {
  local developer_dir
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  [[ -n "$developer_dir" && "$developer_dir" != */CommandLineTools && -x "$developer_dir/usr/bin/xcodebuild" ]] || return 1
  "$developer_dir/usr/bin/xcodebuild" -version >/dev/null 2>&1
}

# Ad-hoc sign the staged bundle and copy it to .build/DuoPrototype.app.
# with_widget=1 keeps the Xcode path's widget codesign and verification.
# Nested Sparkle XPC services keep the signatures from the embedded framework;
# only the framework wrapper is re-signed, matching the previous Xcode script.
publish_staged_app() {
  local with_widget="$1"
  local widget_dir="$STAGED_APP/Contents/PlugIns/DuoWidget.appex"

  find "$STAGED_APP" -print0 | xargs -0 -n1 xattr -c 2>/dev/null || true
  if [[ "$with_widget" == 1 ]]; then
    codesign --force --sign - --entitlements "$ROOT_DIR/Resources/DuoWidget.entitlements" "$widget_dir" >/dev/null
  fi
  local framework
  for framework in "$STAGED_APP"/Contents/Frameworks/*.framework; do
    [[ -d "$framework" ]] || continue
    # Xcode removes development headers when embedding Sparkle's pre-signed
    # framework, which invalidates its original resource seal. Re-sign the
    # embedded framework locally before signing the containing app.
    codesign --force --sign - "$framework" >/dev/null
  done
  # Signing can restore Finder metadata on the nested bundle; remove it before
  # signing and verifying the containing application.
  find "$STAGED_APP" -print0 | xargs -0 -n1 xattr -c 2>/dev/null || true
  codesign --force --sign - "$STAGED_APP" >/dev/null
  if [[ "$with_widget" == 1 ]]; then
    local package
    for package in "$STAGED_APP" "$widget_dir"; do
      xattr -d com.apple.FinderInfo "$package" 2>/dev/null || true
      xattr -d 'com.apple.fileprovider.fpfs#P' "$package" 2>/dev/null || true
    done
  else
    xattr -d com.apple.FinderInfo "$STAGED_APP" 2>/dev/null || true
    xattr -d 'com.apple.fileprovider.fpfs#P' "$STAGED_APP" 2>/dev/null || true
  fi
  # codesign may restore Finder metadata on nested Sparkle XPC bundles. Remove
  # all extended attributes recursively so Launch Services can open the final app.
  xattr -rc "$STAGED_APP" 2>/dev/null || true
  strip_bundle_metadata "$STAGED_APP"
  if [[ "$with_widget" == 1 ]]; then
    codesign --verify --strict "$widget_dir"
  fi
  codesign --verify --deep --strict "$STAGED_APP"

  if [[ "${PACKAGE_APP:-0}" == "1" ]]; then
    local version archive
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")
    archive="$ROOT_DIR/outputs/DuoPrototype-${version}-macOS-arm64.zip"
    mkdir -p "$ROOT_DIR/outputs"
    ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$archive"
    echo "Packaged $archive"
  fi

  rm -rf "$APP_DIR"
  ditto --norsrc "$STAGED_APP" "$APP_DIR"
  xattr -rc "$APP_DIR" 2>/dev/null || true
  strip_bundle_metadata "$APP_DIR"
  codesign --verify --deep --strict "$APP_DIR"
  rm -rf "$STAGING_DIR"
}

build_with_xcode() {
  xcodebuild \
    -project "$ROOT_DIR/DuoPrototype.xcodeproj" \
    -scheme DuoPrototype \
    -configuration Release \
    -derivedDataPath "$ROOT_DIR/.build/xcode" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

  rm -rf "$STAGING_DIR"
  mkdir -p "$STAGING_DIR"
  ditto --norsrc "$ROOT_DIR/.build/xcode/Build/Products/Release/DuoPrototype.app" "$STAGED_APP"
  publish_staged_app 1
  echo "Built $APP_DIR with WidgetKit extension"
}

# SwiftPM links Sparkle as @rpath/Sparkle.framework/Versions/B/Sparkle (or an
# absolute path into the artifact cache). The menu-bar bundle loads it from
# Contents/Frameworks.
trim_leading_space() {
  local value="$1"
  print -r -- "${value#"${value%%[![:space:]]*}"}"
}

framework_name_from_dep() {
  local dep="$1"
  local rest="${dep#*@rpath/}"
  if [[ "$dep" != @rpath/* ]]; then
    rest="$dep"
  fi
  local name="${rest%%.framework/*}"
  name="${name##*/}"
  print -r -- "${name}.framework"
}

locate_framework() {
  local name="$1"
  local -a roots
  roots=("$ROOT_DIR/.build")
  if [[ -n "${HOME:-}" ]]; then
    roots+=("$HOME/Library/Caches/org.swift.swiftpm" "$HOME/Library/org.swift.swiftpm")
  fi
  local root framework_path best="" best_score=-1 score arch
  arch="$(uname -m)"
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' framework_path; do
      [[ "$framework_path" == *".dSYM"* ]] && continue
      [[ "$framework_path" == *".app/Contents/"* ]] && continue
      [[ -e "$framework_path/${name%.framework}" || -e "$framework_path/Versions/B/${name%.framework}" ]] || continue
      score=0
      [[ "$framework_path" == *"/.build/artifacts/"* ]] && score=$((score + 100))
      [[ "$framework_path" == *"/.build/"* ]] && score=$((score + 10))
      [[ "$framework_path" == *"/macos-arm64_x86_64/"* ]] && score=$((score + 50))
      [[ "$framework_path" == *"/macos-${arch}/"* ]] && score=$((score + 40))
      if (( score > best_score )); then
        best="$framework_path"
        best_score=$score
      fi
    done < <(find "$root" -type d -name "$name" -print0 2>/dev/null)
  done
  [[ -n "$best" ]] || return 1
  print -r -- "$best"
}

strip_framework_dev_files() {
  local framework="$1"
  local entry
  # RemoveHeadersOnCopy equivalent. Only the version directories are deleted;
  # Versions/Current is a symlink and must not be followed.
  for entry in "$framework"/Versions/*(/N); do
    [[ -L "$entry" ]] && continue
    rm -rf "$entry/Headers" "$entry/PrivateHeaders" "$entry/Modules"
  done
  rm -f "$framework/Headers" "$framework/PrivateHeaders" "$framework/Modules"
}

prepare_swiftpm_binary() {
  local binary="$1"
  local line dep framework_name suffix source
  if ! otool -l "$binary" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$binary"
  fi
  while IFS= read -r line; do
    dep="$(trim_leading_space "$line")"
    # otool appends " (compatibility version …)". The parenthesis has to stay
    # quoted: an unquoted "(" is a zsh pattern group and aborts the script with
    # "bad pattern: (*" before the app bundle is copied into place.
    dep="${dep%%" ("*}"
    case "$dep" in
      /System/*|/usr/lib/*|/usr/local/lib/*|'')
        continue
        ;;
      *.framework/*)
        ;;
      *)
        continue
        ;;
    esac
    framework_name="$(framework_name_from_dep "$dep")"
    if [[ "$dep" != @rpath/* ]]; then
      suffix="${dep#*"${framework_name}/"}"
      install_name_tool -change "$dep" "@rpath/${framework_name}/${suffix}" "$binary"
      dep="@rpath/${framework_name}/${suffix}"
    fi
    if [[ -d "$STAGED_APP/Contents/Frameworks/$framework_name" ]]; then
      continue
    fi
    if ! source="$(locate_framework "$framework_name")"; then
      echo "error: linked $framework_name was not found under .build to embed in the app." >&2
      exit 1
    fi
    mkdir -p "$STAGED_APP/Contents/Frameworks"
    ditto --norsrc "$source" "$STAGED_APP/Contents/Frameworks/$framework_name"
    chmod -R u+w "$STAGED_APP/Contents/Frameworks/$framework_name"
    strip_framework_dev_files "$STAGED_APP/Contents/Frameworks/$framework_name"
  done < <(otool -L "$binary" | tail -n +2)
}

build_with_swiftpm() {
  local developer_dir reason
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$developer_dir" == */CommandLineTools ]]; then
    reason="the active developer directory is Command Line Tools ($developer_dir), so xcodebuild cannot run"
  elif [[ -z "$developer_dir" ]]; then
    reason="xcodebuild is not available"
  else
    reason="xcodebuild is not usable (developer directory: $developer_dir)"
  fi
  echo "note: $reason. Building .build/DuoPrototype.app with Swift Package Manager. The WidgetKit extension was skipped."
  if ! command -v swift >/dev/null 2>&1; then
    echo "error: swift was not found. Install the Xcode Command Line Tools and re-run ./scripts/build-app.sh." >&2
    exit 1
  fi

  swift build -c release --product DuoPrototype

  local binary="" candidate
  if [[ -x "$ROOT_DIR/.build/release/DuoPrototype" ]]; then
    binary="$ROOT_DIR/.build/release/DuoPrototype"
  else
    while IFS= read -r -d '' candidate; do
      binary="$candidate"
      break
    done < <(find "$ROOT_DIR/.build" -type f -name DuoPrototype -path '*/release/*' ! -path '*.dSYM/*' ! -path '*.app/*' -print0)
  fi
  if [[ -z "$binary" || ! -f "$binary" ]]; then
    echo "error: swift build did not produce a DuoPrototype executable." >&2
    exit 1
  fi

  rm -rf "$STAGING_DIR"
  mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Frameworks"
  cp -p "$binary" "$STAGED_APP/Contents/MacOS/DuoPrototype"
  chmod 755 "$STAGED_APP/Contents/MacOS/DuoPrototype"
  cp "$ROOT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
  printf 'APPLDUOP' > "$STAGED_APP/Contents/PkgInfo"

  local key
  for key in LSUIElement CFBundleIdentifier CFBundleExecutable CFBundleShortVersionString CFBundleVersion; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$STAGED_APP/Contents/Info.plist" >/dev/null
  done

  local resource
  while IFS= read -r -d '' resource; do
    mkdir -p "$STAGED_APP/Contents/Resources"
    ditto --norsrc "$resource" "$STAGED_APP/Contents/Resources/${resource:t}"
  done < <(find "$(dirname "$binary")" -maxdepth 1 -type d -name '*.bundle' -print0)

  prepare_swiftpm_binary "$STAGED_APP/Contents/MacOS/DuoPrototype"

  if [[ ! -d "$STAGED_APP/Contents/Frameworks/Sparkle.framework" ]]; then
    echo "error: Sparkle.framework was linked but could not be embedded in the app bundle." >&2
    exit 1
  fi

  publish_staged_app 0
  echo "Built $APP_DIR without the WidgetKit extension (skipped because xcodebuild is unavailable; install full Xcode and re-run ./scripts/build-app.sh to include the widget)."
}

# Allow tests to source this file without building.
if [[ "${ZSH_EVAL_CONTEXT:-}" == toplevel ]]; then
  if xcodebuild_is_usable; then
    build_with_xcode
  else
    build_with_swiftpm
  fi
fi
