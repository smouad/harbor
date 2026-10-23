#!/bin/sh
# Builds libharbor_adblock.a (release, stripped) for macOS arm64, iOS arm64 and the iOS
# simulator and wraps them in HarborAdblock.xcframework so machines without a Rust
# toolchain can still build Harbor.
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"
# Keep cargo output out of Harbor/ (a filesystem-synchronized Xcode group would
# otherwise copy every target/ file into the app bundle). build/ is gitignored.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PWD/../../../build/AdblockRustFFI-target}"

cargo test --release --locked
cargo build --release --locked --target aarch64-apple-darwin
cargo build --release --locked --target aarch64-apple-ios
cargo build --release --locked --target aarch64-apple-ios-sim
rm -rf HarborAdblock.xcframework
xcodebuild -create-xcframework \
  -library "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libharbor_adblock.a" -headers include \
  -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libharbor_adblock.a" -headers include \
  -library "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libharbor_adblock.a" -headers include \
  -output HarborAdblock.xcframework
ls HarborAdblock.xcframework
