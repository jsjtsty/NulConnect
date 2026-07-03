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
TUN_DIR="$RUST_ROOT/nulconnect-tun"
VENDOR_DIR="$XCODE_ROOT/Vendor/libreatrust"

if [[ ! -d "$LIBREATRUST_DIR" ]]; then
  echo "error: missing libreatrust directory: $LIBREATRUST_DIR" >&2
  exit 1
fi

if [[ ! -d "$TUN_DIR" ]]; then
  echo "error: missing nulconnect-tun directory: $TUN_DIR" >&2
  exit 1
fi

mkdir -p \
  "$VENDOR_DIR/dynamic" \
  "$VENDOR_DIR/static" \
  "$VENDOR_DIR/include"

echo "building libreatrust..."
cargo build --release --manifest-path "$LIBREATRUST_DIR/Cargo.toml"

echo "building nulconnect-tun-helper..."
cargo build --release --manifest-path "$TUN_DIR/Cargo.toml" --bin nulconnect-tun-helper

cp "$LIBREATRUST_DIR/target/release/libreatrust.dylib" "$VENDOR_DIR/dynamic/libreatrust.dylib"
cp "$LIBREATRUST_DIR/target/release/libreatrust.a" "$VENDOR_DIR/static/libreatrust.a"
cp "$LIBREATRUST_DIR/include/libreatrust.h" "$VENDOR_DIR/include/libreatrust.h"
cp "$TUN_DIR/target/release/nulconnect-tun-helper" "$VENDOR_DIR/dynamic/nulconnect-tun-helper"

echo "updated:"
echo "  $VENDOR_DIR/dynamic/libreatrust.dylib"
echo "  $VENDOR_DIR/static/libreatrust.a"
echo "  $VENDOR_DIR/include/libreatrust.h"
echo "  $VENDOR_DIR/dynamic/nulconnect-tun-helper"
