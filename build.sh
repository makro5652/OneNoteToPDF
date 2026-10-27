#!/bin/zsh
# Baut OneNoteToPDF.app (ad-hoc signiert) im Projektordner.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="OneNoteToPDF.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp .build/release/OneNoteToPDF "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>de.makro.OneNoteToPDF</string>
<key>CFBundleName</key><string>OneNote → PDF</string>
<key>CFBundleDisplayName</key><string>OneNote → PDF</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>OneNoteToPDF</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PL
codesign --force --deep --sign - -r='designated => identifier "de.makro.OneNoteToPDF"' "$APP"
echo "Fertig: $PWD/$APP"
