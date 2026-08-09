#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/update-vendor-libs.sh

This builds the Rust libraries and copies the release artifacts into
Vendor/libreatrust for the Xcode project.
EOF
}

if [[ $# -ne 0 ]]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XCODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUST_ROOT="/Volumes/T7S-Projects/Projects/Rust"
LIBREATRUST_DIR="$RUST_ROOT/libreatrust"
HELPER_DIR="$RUST_ROOT/nulconnect-helper"
VENDOR_DIR="$XCODE_ROOT/Vendor/libreatrust"

# Set to 1 when producing a diagnostic build. Keep this at 0 for normal builds.
ENABLE_VERBOSE_LOGS="${ENABLE_VERBOSE_LOGS:-0}"

if [[ ! -d "$LIBREATRUST_DIR" ]]; then
  echo "error: missing libreatrust directory: $LIBREATRUST_DIR" >&2
  exit 1
fi

if [[ ! -d "$HELPER_DIR" ]]; then
  echo "error: missing helper source directory: $HELPER_DIR" >&2
  exit 1
fi

mkdir -p \
  "$VENDOR_DIR/dynamic" \
  "$VENDOR_DIR/static" \
  "$VENDOR_DIR/include"

echo "building libreatrust..."
if [[ "$ENABLE_VERBOSE_LOGS" == "1" ]]; then
  cargo build --release --manifest-path "$LIBREATRUST_DIR/Cargo.toml" --features verbose-logs
else
  cargo build --release --manifest-path "$LIBREATRUST_DIR/Cargo.toml"
fi

echo "building nulconnect-helper..."
if [[ "$ENABLE_VERBOSE_LOGS" == "1" ]]; then
  cargo build --release --manifest-path "$HELPER_DIR/Cargo.toml" --features verbose-logs --bin nulconnect-helper
else
  cargo build --release --manifest-path "$HELPER_DIR/Cargo.toml" --bin nulconnect-helper
fi

cp "$LIBREATRUST_DIR/target/release/libreatrust.dylib" "$VENDOR_DIR/dynamic/libreatrust.dylib"
cp "$LIBREATRUST_DIR/target/release/libreatrust.a" "$VENDOR_DIR/static/libreatrust.a"
cp "$LIBREATRUST_DIR/include/libreatrust.h" "$VENDOR_DIR/include/libreatrust.h"
cp "$HELPER_DIR/target/release/nulconnect-helper" "$VENDOR_DIR/dynamic/nulconnect-helper"

echo "updated:"
echo "  $VENDOR_DIR/dynamic/libreatrust.dylib"
echo "  $VENDOR_DIR/static/libreatrust.a"
echo "  $VENDOR_DIR/include/libreatrust.h"
echo "  $VENDOR_DIR/dynamic/nulconnect-helper"
