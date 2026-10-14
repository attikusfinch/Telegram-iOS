#!/bin/bash
set -euo pipefail

wallet_theme_tests_dir="$(cd "$(dirname "$0")" && pwd)"
wallet_theme_test_output="$(mktemp -d "${TMPDIR:-/tmp}/wallet-gift-theme-tests.XXXXXX")"
trap 'rm -rf "$wallet_theme_test_output"' EXIT

swiftc \
    "$wallet_theme_tests_dir/../Sources/WalletGiftThemeStore.swift" \
    "$wallet_theme_tests_dir/WalletGiftThemeStoreTests.swift" \
    -o "$wallet_theme_test_output/wallet-gift-theme-tests"

"$wallet_theme_test_output/wallet-gift-theme-tests"
