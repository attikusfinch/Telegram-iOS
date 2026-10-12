#!/bin/sh
set -eu

test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(git -C "$test_directory" rev-parse --show-toplevel)
executable="$repository_root/build-input/gift-size-layout-tests"
mkdir -p "$repository_root/build-input"

xcrun swiftc \
    "$test_directory/../Sources/GiftSizeLayout.swift" \
    "$test_directory/GiftSizeLayoutTests.swift" \
    -o "$executable"
"$executable"
