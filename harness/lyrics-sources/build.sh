#!/bin/sh
# build.sh: builds check.m against this checkout's lyrics sources and word splitting as a Mac Catalyst
# binary and runs it, so no simulator is needed. Arguments go to the check (saved replies to read).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../../tweak/Sources" && pwd)
LS="$SRC/Shared/LyricsSources"
mkdir -p "$HERE/build"
xcrun -sdk macosx clang -target arm64-apple-ios17.0-macabi -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -iframework "$(xcrun --sdk macosx --show-sdk-path)/System/iOSSupport/System/Library/Frameworks" -fobjc-arc -g -Wall -I"$SRC" -DSG_VERSION=\"0.0.0\" \
    "$HERE/check.m" "$LS/KuGou.m" "$LS/QQMusic.m" "$LS/NetEase.m" "$LS/Musixmatch.m" "$LS/LrcLib.m" "$LS/Lyricsfile.m" "$LS/SongMatch.m" "$SRC/Shared/Lyrics/KaraokeTiming.m" "$SRC/Shared/AdBlock/Protobuf.m" \
    -framework UIKit -framework Foundation -lz -o "$HERE/build/check"
"$HERE/build/check" "$@"
