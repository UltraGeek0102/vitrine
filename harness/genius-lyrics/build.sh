#!/bin/sh
# build.sh: builds check.m against this checkout's Genius.m and the Genius search in Meanings.m as a
# Mac Catalyst binary and runs it, so no simulator is needed. `./build.sh live` also asks genius.com.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../../tweak/Sources" && pwd)
mkdir -p "$HERE/build"
xcrun -sdk macosx clang -target arm64-apple-ios17.0-macabi -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -iframework "$(xcrun --sdk macosx --show-sdk-path)/System/iOSSupport/System/Library/Frameworks" -fobjc-arc -g -Wall -I"$SRC" -DSG_VERSION=\"0.0.0\" \
    "$HERE/check.m" "$SRC/Shared/LyricsSources/Genius.m" "$SRC/Shared/LyricsSources/LrcLib.m" "$SRC/Shared/LyricsSources/Lyricsfile.m" "$SRC/Shared/LyricsSources/SongMatch.m" "$SRC/Shared/LyricsSources/QQMusic.m" "$SRC/Shared/LyricsMeanings/Meanings.m" "$SRC/Shared/Lyrics/KaraokeTiming.m" "$SRC/Shared/AdBlock/Protobuf.m" \
    -framework UIKit -framework Foundation -o "$HERE/build/check"
"$HERE/build/check" "$@"
