#!/bin/zsh
# Builds the "Speaker Sync" audio driver. It's BlackHole 2ch with a new name, so your
# Sound menu says "Speaker Sync" instead of "BlackHole 2ch". Volume keys still work.
#
# BlackHole is made by Existential Audio and it's GPL-3.0: https://github.com/ExistentialAudio/BlackHole
# You need full Xcode for this one. It drops the driver at build/SpeakerSync.driver
set -e
cd "$(dirname "$0")/.."
ROOT=$PWD
BH_COMMIT=6008d29
SRC=build/driver-src
OUT=build/SpeakerSync.driver

rm -rf "$SRC" "$OUT"
mkdir -p build
git clone -q https://github.com/ExistentialAudio/BlackHole.git "$SRC"
git -C "$SRC" checkout -q "$BH_COMMIT"

# Give the driver the Speaker Sync icon if the app's been built already.
if [ -f build/Speaker\ Sync.app/Contents/Resources/AppIcon.icns ]; then
  cp build/Speaker\ Sync.app/Contents/Resources/AppIcon.icns "$SRC/BlackHole/BlackHole.icns"
fi

bundleID="io.github.callmefoad.speakersync.driver"
cd "$SRC"
xcodebuild -quiet \
  -project BlackHole.xcodeproj \
  -configuration Release \
  -target BlackHole \
  CONFIGURATION_BUILD_DIR="$ROOT/build/driver-out" \
  PRODUCT_BUNDLE_IDENTIFIER=$bundleID \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS
  kDriver_Name=\"SpeakerSync\"
  kDevice_Name=\"Speaker\ Sync\"
  kManufacturer_Name=\"Speaker\ Sync\ (BlackHole)\"
  kPlugIn_BundleID=\"'$bundleID'\"
  kPlugIn_Icon=\"BlackHole.icns\"
  kNumber_Of_Channels=2'
cd "$ROOT"
mv build/driver-out/BlackHole.driver "$OUT"
codesign --force --deep -s - "$OUT"
echo "Built: $OUT"
echo
echo "To install it yourself (macOS asks for your password), run:"
echo "  sudo cp -R \"$ROOT/$OUT\" /Library/Audio/Plug-Ins/HAL/ && sudo killall coreaudiod"
echo "Or just hit Install Driver in the app."
