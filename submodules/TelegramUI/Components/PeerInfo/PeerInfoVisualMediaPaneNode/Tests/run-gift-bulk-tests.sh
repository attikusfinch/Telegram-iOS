#!/bin/sh
set -eu

test_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(git -C "$test_directory" rev-parse --show-toplevel)
build_directory="$repository_root/build-input/gift-bulk-tests"
mkdir -p "$build_directory"

# Build the repository's actual signal runtime; the tests make no Telegram calls.
xcrun swiftc -swift-version 5 -emit-library -emit-module -module-name SwiftSignalKit \
    "$repository_root"/submodules/SSignalKit/SwiftSignalKit/Source/*.swift \
    -emit-module-path "$build_directory/SwiftSignalKit.swiftmodule" \
    -o "$build_directory/libSwiftSignalKit.dylib"
xcrun swiftc -swift-version 5 -I "$build_directory" -L "$build_directory" -lSwiftSignalKit \
    -Xlinker -rpath -Xlinker "$build_directory" \
    "$test_directory/../Sources/GiftBulkActionsSupport.swift" \
    "$test_directory/GiftBulkActionsSupportTests.swift" \
    -o "$build_directory/gift-bulk-action-tests"
"$build_directory/gift-bulk-action-tests"

xcrun swiftc -swift-version 5 -emit-library -emit-module -module-name TelegramCore \
    -D GIFT_BULK_TEST_CORE -I "$build_directory" -L "$build_directory" -lSwiftSignalKit \
    "$test_directory/GiftBulkActionsTestStubs.swift" \
    -emit-module-path "$build_directory/TelegramCore.swiftmodule" \
    -o "$build_directory/libTelegramCore.dylib"
xcrun swiftc -swift-version 5 -emit-library -emit-module -module-name AccountContext \
    -D GIFT_BULK_TEST_CONTEXT -I "$build_directory" -L "$build_directory" -lSwiftSignalKit -lTelegramCore \
    "$test_directory/GiftBulkActionsTestStubs.swift" \
    -emit-module-path "$build_directory/AccountContext.swiftmodule" \
    -o "$build_directory/libAccountContext.dylib"
xcrun swiftc -swift-version 5 -I "$build_directory" -L "$build_directory" \
    -lSwiftSignalKit -lTelegramCore -lAccountContext \
    -Xlinker -rpath -Xlinker "$build_directory" \
    "$test_directory/../Sources/GiftBulkActionsSupport.swift" \
    "$test_directory/../Sources/GiftBulkActions.swift" \
    "$test_directory/GiftBulkActionsTests.swift" \
    -o "$build_directory/gift-bulk-api-tests"
"$build_directory/gift-bulk-api-tests"
