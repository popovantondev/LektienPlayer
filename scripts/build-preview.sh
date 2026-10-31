#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
build_args=(-c release)
if [[ -n "${LEKTIEN_BUILD_DIRECTORY:-}" ]]; then
    build_args+=(--scratch-path "$LEKTIEN_BUILD_DIRECTORY")
fi
xcrun swift build "${build_args[@]}"
bin_dir="$(xcrun swift build "${build_args[@]}" --show-bin-path)"
mkdir -p previews
preview_dir="$(mktemp -d "$project_dir/previews/codex-XXXXXX")"
app_dir="$preview_dir/Lektien Player.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/LektienOnlineUebersetzung" "$app_dir/Contents/MacOS/"
cp docs/CLEAN_MAC_README.md "$app_dir/Contents/Resources/CLEAN_MAC_README.md"
# The app resolves packaged resources before falling back to SwiftPM during tests.
for resource in "$bin_dir"/*.bundle; do
    cp -R "$resource" "$app_dir/Contents/Resources/"
done
xcrun python3 scripts/package-runtime.py "${LEKTIEN_RUNTIME_DIRECTORY:-$project_dir/Runtime}" "$app_dir/Contents/Resources/Runtime"
for library in "$app_dir/Contents/Resources/Runtime/lib/"*.dylib; do
    codesign --force --sign - "$library"
done
icon_dir="$preview_dir/AppIcon.iconset"
mkdir "$icon_dir"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon-transparent.png --out "$icon_dir/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Assets/AppIcon-transparent.png --out "$icon_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LektienOnlineUebersetzung</string>
<key>CFBundleIdentifier</key><string>local.lektien.player.preview</string>
<key>CFBundleName</key><string>Lektien Player</string>
<key>CFBundleDevelopmentRegion</key><string>de</string>
<key>CFBundleLocalizations</key><array><string>de</string><string>en</string><string>ru</string></array>
<key>CFBundleDisplayName</key><string>Lektien Player</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSLocalNetworkUsageDescription</key><string>Ausgewählte Videos im Heimnetz auf anderen Geräten ansehen.</string>
</dict></plist>
PLIST
if [[ -n "${LEKTIEN_PREVIEW_IDENTIFIER:-}" ]]; then
    [[ "$LEKTIEN_PREVIEW_IDENTIFIER" =~ ^[A-Za-z0-9.-]+$ ]] || { printf '%s\n' 'Invalid preview identifier' >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $LEKTIEN_PREVIEW_IDENTIFIER" "$app_dir/Contents/Info.plist"
fi
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
