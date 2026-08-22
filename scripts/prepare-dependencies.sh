#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/prepare-dependencies.sh [--arch arm64|x86_64]

Downloads the prebuilt macOS dependencies from their GitHub Releases and
stages them for the Xcode project. No Rust toolchain is required.

Environment overrides:
  LIBREATRUST_VERSION       libreatrust release tag (default: v0.2.3)
  NULCONNECT_HELPER_VERSION helper release tag (default: v0.2.3)
  NULCONNECT_DEPENDENCY_ROOT output directory for staged files
  NULCONNECT_DEPENDENCY_CACHE_DIR directory for downloaded archives
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCH="${NULCONNECT_ARCH:-$(uname -m)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      ARCH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

case "$ARCH" in
  arm64|x86_64) ;;
  *)
    echo "error: unsupported macOS architecture: $ARCH" >&2
    exit 2
    ;;
esac

LIBREATRUST_VERSION="${LIBREATRUST_VERSION:-v0.2.3}"
NULCONNECT_HELPER_VERSION="${NULCONNECT_HELPER_VERSION:-v0.2.3}"
LIBREATRUST_REPOSITORY="${LIBREATRUST_REPOSITORY:-https://github.com/jsjtsty/libreatrust}"
HELPER_REPOSITORY="${HELPER_REPOSITORY:-https://github.com/jsjtsty/nulconnect-helper}"
DEPENDENCY_ROOT="${NULCONNECT_DEPENDENCY_ROOT:-$PROJECT_DIR/.build/dependencies/$ARCH}"
CACHE_DIR="${NULCONNECT_DEPENDENCY_CACHE_DIR:-$PROJECT_DIR/.build/downloads}"

marker="$DEPENDENCY_ROOT/.complete"
if [[ -f "$marker" ]] && grep -Fxq "architecture=$ARCH" "$marker" \
  && grep -Fxq "libreatrust=$LIBREATRUST_VERSION" "$marker" \
  && grep -Fxq "nulconnect-helper=$NULCONNECT_HELPER_VERSION" "$marker" \
  && [[ -f "$DEPENDENCY_ROOT/libreatrust/dynamic/libreatrust.dylib" ]] \
  && [[ -f "$DEPENDENCY_ROOT/libreatrust/static/libreatrust.a" ]] \
  && [[ -f "$DEPENDENCY_ROOT/libreatrust/include/libreatrust.h" ]] \
  && [[ -x "$DEPENDENCY_ROOT/libreatrust/dynamic/nulconnect-helper" ]]; then
  echo "dependencies already prepared: $DEPENDENCY_ROOT"
  exit 0
fi

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "error: tar is required" >&2; exit 1; }

mkdir -p "$CACHE_DIR"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nulconnect-dependencies.XXXXXX")"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

download() {
  local url="$1"
  local destination="$2"
  if [[ ! -f "$destination" ]]; then
    echo "downloading $url"
    curl --fail --location --retry 3 --retry-all-errors --silent --show-error \
      "$url" -o "$destination"
  fi
}

libreatrust_archive="$CACHE_DIR/libreatrust-${LIBREATRUST_VERSION}-${ARCH}.tar.gz"
helper_archive="$CACHE_DIR/nulconnect-helper-${NULCONNECT_HELPER_VERSION}-${ARCH}.tar.gz"
download "$LIBREATRUST_REPOSITORY/releases/download/$LIBREATRUST_VERSION/libreatrust-macos-$ARCH.tar.gz" "$libreatrust_archive"
download "$HELPER_REPOSITORY/releases/download/$NULCONNECT_HELPER_VERSION/nulconnect-helper-macos-$ARCH.tar.gz" "$helper_archive"

libreatrust_extract="$work_dir/libreatrust"
helper_extract="$work_dir/helper"
mkdir -p "$libreatrust_extract" "$helper_extract"
tar -xzf "$libreatrust_archive" -C "$libreatrust_extract"
tar -xzf "$helper_archive" -C "$helper_extract"

libreatrust_dylib="$(find "$libreatrust_extract" -type f -name libreatrust.dylib -print -quit)"
helper_binary="$(find "$helper_extract" -type f -name nulconnect-helper -print -quit)"
if [[ -z "$libreatrust_dylib" || -z "$helper_binary" ]]; then
  echo "error: downloaded dependency archive has an unexpected layout" >&2
  exit 1
fi
libreatrust_root="$(dirname "$libreatrust_dylib")"
helper_root="$(dirname "$helper_binary")"

for required in \
  "$libreatrust_root/libreatrust.dylib" \
  "$libreatrust_root/libreatrust.a" \
  "$libreatrust_root/libreatrust.h" \
  "$helper_root/nulconnect-helper"; do
  [[ -f "$required" ]] || { echo "error: missing dependency file: $required" >&2; exit 1; }
done

rm -rf "$DEPENDENCY_ROOT"
mkdir -p \
  "$DEPENDENCY_ROOT/libreatrust/dynamic" \
  "$DEPENDENCY_ROOT/libreatrust/static" \
  "$DEPENDENCY_ROOT/libreatrust/include"
cp "$libreatrust_root/libreatrust.dylib" "$DEPENDENCY_ROOT/libreatrust/dynamic/"
cp "$libreatrust_root/libreatrust.a" "$DEPENDENCY_ROOT/libreatrust/static/"
cp "$libreatrust_root/libreatrust.h" "$DEPENDENCY_ROOT/libreatrust/include/"
cp "$helper_root/nulconnect-helper" "$DEPENDENCY_ROOT/libreatrust/dynamic/"
chmod +x "$DEPENDENCY_ROOT/libreatrust/dynamic/nulconnect-helper"

{
  echo "architecture=$ARCH"
  echo "libreatrust=$LIBREATRUST_VERSION"
  echo "nulconnect-helper=$NULCONNECT_HELPER_VERSION"
} > "$marker"

echo "prepared dependencies: $DEPENDENCY_ROOT"
