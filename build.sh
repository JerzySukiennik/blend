#!/bin/bash
# Blend: builds, bundles and signs Blend.app. Usage: ./build.sh [install]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
SCRATCH="Niepotrzebne/build"
nice -n 10 swift build -c release --scratch-path "$SCRATCH" -j 4
BIN="$SCRATCH/release"
ICONS="Niepotrzebne/icon"
if [ ! -f "$ICONS/AppIcon.icns" ]; then
  mkdir -p "$ICONS"
  swift Niepotrzebne/tools/make-icon.swift "$ICONS/AppIcon.iconset"
  iconutil -c icns "$ICONS/AppIcon.iconset" -o "$ICONS/AppIcon.icns"
fi
OUT="Niepotrzebne/Blend.app"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN/Blend" "$OUT/Contents/MacOS/Blend.new"
mv -f "$OUT/Contents/MacOS/Blend.new" "$OUT/Contents/MacOS/Blend"
cp "$ICONS/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>fun.gzowo.blend</string>
<key>CFBundleName</key><string>Blend</string>
<key>CFBundleDisplayName</key><string>Blend</string>
<key>CFBundleExecutable</key><string>Blend</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.music</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Gzowo Labs</string>
</dict></plist>
PLIST
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
codesign --force --sign "${IDENTITY:--}" "$OUT" 2>/dev/null
if [ "${1:-}" = "install" ]; then
  rm -rf "/Applications/Blend.app"
  cp -R "$OUT" "/Applications/Blend.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Blend.app" >/dev/null 2>&1 || true
  echo "/Applications/Blend.app"
else
  echo "$OUT"
fi
