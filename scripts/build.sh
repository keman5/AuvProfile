#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077

work_root="$PWD/.artifacts"
mkdir -p "$work_root"
work="$(mktemp -d "$work_root/build.XXXXXX")"
staging=
destination="/Applications/AuvProfile.app"

cleanup() {
    if [[ -n "$staging" ]]; then
        if [[ ! -e "$destination" && -d "$staging/previous.app" ]]; then
            mv "$staging/previous.app" "$destination" || return
        fi
        rm -rf "$staging"
    fi
    rm -rf "$work"
    rmdir "$work_root" 2>/dev/null || true
}
trap cleanup EXIT

if command -v go >/dev/null; then
    go clean -cache
fi

export PATH="$PATH:$HOME/.cargo/bin"
if ! cargo --version >/dev/null 2>&1; then
    toolchain="$(ls -1 "$HOME/.rustup/toolchains" 2>/dev/null | head -n 1 || true)"
    [[ -n "$toolchain" ]] && export RUSTUP_TOOLCHAIN="$toolchain"
fi
export CARGO_TARGET_DIR="$work/rust"
cargo test --locked --manifest-path config/Cargo.toml
cargo build --release --locked --manifest-path config/Cargo.toml
export AUVPROFILE_CONFIG_HELPER="$CARGO_TARGET_DIR/release/auvprofile-config"
swift test --scratch-path "$work/swift"
if [[ "${1:-}" == --test ]]; then exit 0; fi
swift build -c release --scratch-path "$work/swift"

bundle="$work/AuvProfile.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Helpers" "$bundle/Contents/Resources"
cp "$work/swift/release/AuvProfile" "$bundle/Contents/MacOS/"
cp "$AUVPROFILE_CONFIG_HELPER" "$bundle/Contents/Helpers/"
"$work/swift/release/AuvProfile" --write-iconset "$work/AppIcon.iconset"
iconutil -c icns "$work/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
build_number="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$destination/Contents/Info.plist" 2>/dev/null || true)"
[[ "$build_number" =~ ^[0-9]+$ ]] || build_number=0
build_number=$((build_number + 1))
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>AuvProfile</string>
<key>CFBundleDisplayName</key><string>AuvProfile</string>
<key>CFBundleExecutable</key><string>AuvProfile</string>
<key>CFBundleIdentifier</key><string>com.keman5.AuvProfile</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
signing_identity="${AUVPROFILE_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ { if (!seen++) print $2 }')"
fi
signing_identity="${signing_identity:--}"
for item in "$bundle/Contents/Helpers/auvprofile-config" "$bundle"; do
    codesign --force --options runtime --timestamp=none --sign "$signing_identity" "$item"
done
codesign --verify --deep --strict "$bundle"
staging="$(mktemp -d /Applications/.auvprofile.XXXXXX)"
/usr/bin/ditto "$bundle" "$staging/AuvProfile.app"
codesign --verify --deep --strict "$staging/AuvProfile.app"
running="$(pgrep -f "^$destination/Contents/MacOS/AuvProfile$" || true)"
if [[ -n "$running" ]]; then
    kill -TERM $running 2>/dev/null || true
    for attempt in {1..30}; do
        if ! pgrep -f "^$destination/Contents/MacOS/AuvProfile$" >/dev/null; then break; fi
        sleep 0.2
    done
    if pgrep -f "^$destination/Contents/MacOS/AuvProfile$" >/dev/null; then
        echo "AuvProfile is still running." >&2
        exit 1
    fi
fi
if [[ -e "$destination" ]]; then mv "$destination" "$staging/previous.app"; fi
mv "$staging/AuvProfile.app" "$destination"
if [[ -n "$running" ]]; then open -g -a "$destination"; fi
echo "Installed $destination (build $build_number)"
