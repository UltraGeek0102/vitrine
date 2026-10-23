#!/bin/sh
# build.sh: the redesign's Lyrics page (Redesigned/Lyrics/LyricsLookSettings.m) for the simulator: its preview,
# the real lyrics view playing the sample song, the presets and the sliders' sheet, on the real Settings/
# framework, with ../lyrics/stubs.m standing in for the player.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../../tweak/Sources" && pwd)
APP=$HERE/build/LyricsPageHarness.app
rm -rf "$HERE/build"; mkdir -p "$APP"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -fobjc-arc -g -O0 -DSG_HARNESS_SETTINGS \
    -I"$SRC" -I"$SRC/Redesigned/Lyrics" -isysroot "$SDK" -Wall -Wno-deprecated-declarations \
    "$HERE/main.m" "$HERE/../scene.m" "$HERE/../lyrics/stubs.m" "$HERE/../sing/button/sing-stubs.m" \
    "$SRC"/Redesigned/Lyrics/LyricsLookSettings.m "$SRC"/Redesigned/Lyrics/LyricsLook.m \
    "$SRC"/Redesigned/Lyrics/SGRKaraokeView.m "$SRC"/Redesigned/Lyrics/LyricsText.m "$SRC"/Redesigned/Lyrics/SGRSingButton.m \
    "$SRC"/Redesigned/Lyrics/MeaningSheet.m "$SRC"/Shared/LyricsMeanings/Meanings.m "$SRC"/Shared/LyricsSources/SongMatch.m \
    "$SRC"/Shared/Lyrics/KaraokeTiming.m "$SRC"/Shared/Lyrics/Romanise.m "$SRC"/Shared/AdBlock/Protobuf.m \
    "$SRC"/Redesigned/Kit/SGRTokens.m "$SRC"/Redesigned/Kit/SGRGlass.m \
    "$SRC"/Settings/SGPage.m "$SRC"/Settings/SGPageStyle.m "$SRC"/Settings/SGModPage.m "$SRC"/Settings/SGGlowSwitch.m \
    "$SRC"/Core/SGLog.m "$SRC"/Core/SGPrefs.m "$SRC"/Core/SGGlass.m "$SRC"/Core/SGViewTree.m "$SRC"/Core/SGFlagForce.m "$SRC"/Core/SGUIMode.m \
    -framework UIKit -framework QuartzCore -framework CoreGraphics -framework CoreText -framework Foundation -framework Symbols -framework NaturalLanguage \
    -o "$APP/LyricsPageHarness"

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LyricsPageHarness</string>
<key>CFBundleIdentifier</key><string>com.vojta.lyricspageharness</string>
<key>CFBundleName</key><string>Lyrics page</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>UIUserInterfaceStyle</key><string>Dark</string>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict>
  <key>UIApplicationSupportsMultipleScenes</key><false/>
  <key>UISceneConfigurations</key><dict>
    <key>UIWindowSceneSessionRoleApplication</key><array><dict>
      <key>UISceneConfigurationName</key><string>Default</string>
      <key>UISceneDelegateClassName</key><string>SGRHarnessScene</string>
    </dict></array>
  </dict>
</dict>
</dict></plist>
PLIST
codesign -f -s - "$APP" >/dev/null 2>&1
echo "built $APP"
