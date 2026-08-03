#!/bin/sh
# run.sh - build the shared library and exercise it from C
#
# These are the tests that actually prove substitutability. Everything in the
# Swift package proves the codec is correct; only a C program compiled against
# the real header and linked against the built .so proves the ABI is.
#
# roundtrip.c covers the TJ3 API that new code calls. legacy.c covers the 1.x
# and 2.x API that the large body of already-compiled software calls, which is
# the one that decides whether this is a drop-in for anything installed.
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

status=0
for program in roundtrip legacy; do
    cc -std=c99 -Wall -Wextra \
        -I "$root/Sources/CTurboJPEG/include" \
        -o "$build/$program" "$root/Conformance/$program.c" \
        -L "$build" -lturbojpeg

    echo
    echo "== $program =="
    if ! LD_LIBRARY_PATH="$build" DYLD_LIBRARY_PATH="$build" "$build/$program"; then
        status=1
    fi
done

exit $status
