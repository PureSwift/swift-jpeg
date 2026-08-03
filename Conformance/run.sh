#!/bin/sh
# run.sh - build the shared library and exercise it from C
#
# This is the test that actually proves substitutability. Everything in the
# Swift package proves the codec is correct; only a C program compiled against
# the real header and linked against the built .so proves the ABI is.
#
# Point LD_LIBRARY_PATH at a real libjpeg-turbo instead and the same program
# should behave identically. That comparison is the point of writing it in C.
#
#   usage: Conformance/run.sh [build-directory]

set -e

root=$(cd "$(dirname "$0")/.." && pwd)
build="${1:-$root/.build/conformance}"

cmake -S "$root" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build "$build"

cc -std=c99 -Wall -Wextra \
    -I "$root/Sources/CTurboJPEG/include" \
    -o "$build/roundtrip" "$root/Conformance/roundtrip.c" \
    -L "$build" -lturbojpeg

LD_LIBRARY_PATH="$build" DYLD_LIBRARY_PATH="$build" "$build/roundtrip"
