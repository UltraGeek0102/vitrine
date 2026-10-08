#!/bin/sh
# build.sh [new|old]: the lyrics harness against this checkout's sources, or against HEAD's (old), for
# a before and after of the same song on the same clock.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
VARIANT=${1:-new}
OUT=$HERE/build/$VARIANT
APP=$OUT/LyricsHarness.app
rm -rf "$OUT"; mkdir -p "$APP"

SRC=$REPO/tweak/Sources
if [ "$VARIANT" = old ]; then
    git -C "$REPO" archive HEAD tweak/Sources | tar -x -C "$OUT"
    SRC=$OUT/tweak/Sources
fi

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -fobjc-arc -g ${OPT:--O0} \
    -I"$SRC" -I"$SRC/Redesigned/Lyrics" -isysroot "$SDK" -Wall -Wno-deprecated-declarations \
    "$HERE/main.m" "$HERE/../scene.m" "$HERE/stubs.m" \
    "$SRC"/Redesigned/Lyrics/SGRKaraokeView.m $( [ -f "$SRC"/Redesigned/Lyrics/LyricsText.m ] && echo "$SRC"/Redesigned/Lyrics/LyricsText.m ) $( [ -f "$SRC"/Redesigned/Lyrics/LyricsLook.m ] && echo "$SRC"/Redesigned/Lyrics/LyricsLook.m ) "$SRC"/Shared/Lyrics/KaraokeTiming.m $( [ -f "$SRC"/Shared/Lyrics/Romanise.m ] && echo "$SRC"/Shared/Lyrics/Romanise.m ) "$SRC"/Shared/AdBlock/Protobuf.m \
    "$SRC"/Shared/LyricsSources/SGTTML.m "$SRC"/Redesigned/Kit/SGRTokens.m \
    $( [ -f "$SRC"/Shared/LyricsMeanings/Meanings.m ] && echo "$SRC"/Shared/LyricsMeanings/Meanings.m "$SRC"/Redesigned/Lyrics/MeaningSheet.m ) \
    "$SRC"/Core/SGLog.m "$SRC"/Core/SGPrefs.m "$SRC"/Core/SGGlass.m \
    $( [ -f "$SRC"/Redesigned/Lyrics/SGRSingButton.m ] && echo "$SRC"/Redesigned/Lyrics/SGRSingButton.m "$SRC"/Redesigned/Kit/SGRGlass.m "$HERE"/../sing/button/sing-stubs.m ) \
    -framework UIKit -framework QuartzCore -framework CoreGraphics -framework CoreText -framework Foundation -framework Symbols -framework NaturalLanguage \
    -o "$APP/LyricsHarness"

cp "$HERE"/fixtures/*.ttml "$HERE"/fixtures/*.lrc "$HERE"/fixtures/*.json "$HERE"/fixtures/*.txt "$APP/"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LyricsHarness</string>
<key>CFBundleIdentifier</key><string>com.vojta.lyricsharness.$VARIANT</string>
<key>CFBundleName</key><string>Lyrics $VARIANT</string>
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
