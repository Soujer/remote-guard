#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-1.4.0}"
out="${2:-release/macos}"
case "$version" in *[!0-9.]*|'') echo 'Invalid release version' >&2; exit 1;; esac
mkdir -p "$out"
out="$(cd "$out" && pwd)"
app="$out/RemoteGuard.app"
if [ -e "$app" ]; then echo 'Output app already exists' >&2; exit 1; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -O -sdk "$sdk" -target "${arch}-apple-macosx13.0" macos/native/*.swift -o "$out/RemoteGuard-$arch"
done
lipo -create "$out/RemoteGuard-arm64" "$out/RemoteGuard-x86_64" -output "$app/Contents/MacOS/RemoteGuard"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.soujer.remote-guard</string>
<key>CFBundleName</key><string>RemoteGuard</string>
<key>CFBundleDisplayName</key><string>远程守护</string>
<key>CFBundleExecutable</key><string>RemoteGuard</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>确认远程连接后，仅在本机加密保存屏幕画面，不录声音。</string>
</dict></plist>
EOF
printf 'version=%s\ncommit=%s\n' "$version" "$(git rev-parse HEAD)" > "$app/Contents/Resources/VERSION"
cp README.md LICENSE "$app/Contents/Resources/"
codesign --force --sign - --identifier com.soujer.remote-guard "$app"
codesign --verify --deep --strict "$app"
lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/RemoteGuard"
zip="$out/remote-guard-macos-universal-v${version}.zip"
ditto -c -k --keepParent --norsrc "$app" "$zip"
(cd "$out" && shasum -a 256 "$(basename "$zip")" > "SHA256SUMS-macos-v${version}.txt")
printf 'Built %s\n' "$zip"
