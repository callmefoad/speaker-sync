#!/bin/zsh
# Builds Speaker Sync.app and installs it to ~/Applications
set -e
cd "$(dirname "$0")"
APP="build/Speaker Sync.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon
ICONSET=build/AppIcon.iconset
mkdir -p $ICONSET
swift make_icon.swift build/icon_1024.png >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns"

swiftc -O -parse-as-library main.swift -o "$APP/Contents/MacOS/SpeakerSync"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Speaker Sync</string>
  <key>CFBundleDisplayName</key><string>Speaker Sync</string>
  <key>CFBundleIdentifier</key><string>io.github.callmefoad.speakersync</string>
  <key>CFBundleExecutable</key><string>SpeakerSync</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Speaker Sync listens to the BlackHole virtual cable so it can send your Mac's audio to both speakers.</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/"Speaker Sync.app"
cp -R "$APP" ~/Applications/
touch ~/Applications/"Speaker Sync.app"
echo "Installed: ~/Applications/Speaker Sync.app"
