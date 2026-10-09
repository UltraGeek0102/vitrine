#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter -I stub -I ../../tweak/Sources \
    -framework Foundation check.m ../../tweak/Sources/Shared/AdBlock/RadioModes.m -o build/check
build/check
SG_RADIO_TEST_OFF=1 build/check
