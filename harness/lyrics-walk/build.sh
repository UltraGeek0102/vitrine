#!/bin/sh
# build.sh: builds check.m against this checkout's walk and pick (LyricsSources.m, LyricsPick.m) as a Mac
# Catalyst binary and runs it, so no simulator and no network is needed.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../../tweak/Sources" && pwd)
LS="$SRC/Shared/LyricsSources"
mkdir -p "$HERE/build"
xcrun -sdk macosx clang -target arm64-apple-ios17.0-macabi -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -iframework "$(xcrun --sdk macosx --show-sdk-path)/System/iOSSupport/System/Library/Frameworks" -fobjc-arc -g -Wall -I"$SRC" -DSG_VERSION=\"0.0.0\" \
    "$HERE/check.m" "$LS/LyricsSources.m" "$LS/LyricsPick.m" "$SRC/Shared/Lyrics/KaraokeTiming.m" "$SRC/Shared/AdBlock/Protobuf.m" "$SRC/Core/SGPrefs.m" \
    -framework UIKit -framework Foundation -o "$HERE/build/check"
"$HERE/build/check" "$@"
