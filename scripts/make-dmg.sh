#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/make-dmg.sh /path/to/NulConnect.app [output-dir]

Examples:
  scripts/make-dmg.sh build/Release/NulConnect.app
  scripts/make-dmg.sh /Users/me/Builds/NulConnect.app dist
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

APP_PATH="$1"
OUTPUT_DIR="${2:-$(pwd)/dist}"

if [[ ! -d "$APP_PATH" || "${APP_PATH##*.}" != "app" ]]; then
  echo "error: expected a .app bundle, got: $APP_PATH" >&2
  exit 1
fi

if [[ ! -f "$APP_PATH/Contents/Info.plist" ]]; then
  echo "error: missing Info.plist in bundle: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

info_plist="$APP_PATH/Contents/Info.plist"
app_name="$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' "$info_plist" 2>/dev/null || basename "$APP_PATH" .app)"
exe_name="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$info_plist" 2>/dev/null || basename "$APP_PATH" .app)"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$info_plist" 2>/dev/null || echo "unknown")"

binary_path="$APP_PATH/Contents/MacOS/$exe_name"
if [[ -x "$binary_path" ]]; then
  archs="$(lipo -archs "$binary_path" 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^(arm64|x86_64|arm64e|i386|ppc|ppc64)$/) {
          out = out (out ? "-" : "") $i
        }
      }
    }
    END {
      print out
    }
  ')"
  if [[ -z "$archs" ]]; then
    archs="unknown-arch"
  fi
else
  archs="unknown-arch"
fi

safe_name() {
  printf '%s' "$1" | tr ' /' '_-' | tr -cd '[:alnum:]._+-'
}

safe_app_name="$(safe_name "$app_name")"
safe_version="$(safe_name "$version")"
safe_archs="$(safe_name "$archs")"

volume_name="${safe_app_name}-${safe_version}-${safe_archs}"
dmg_name="${safe_app_name}-${safe_version}-${safe_archs}.dmg"
dmg_path="$OUTPUT_DIR/$dmg_name"

echo "app:    $APP_PATH"
echo "output: $dmg_path"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DMGBUILD_VERSION="1.6.5"
DMGBUILD_VENV="${NULCONNECT_DMGBUILD_VENV:-$PROJECT_DIR/.build/dmgbuild-venv}"

# dmgbuild writes the Finder window layout itself. Scripting Finder (as
# create-dmg does) records the build machine's Finder preferences, such as
# the tab bar, and pushes the icons out of place.
ensure_dmgbuild() {
  local dmgbuild="$DMGBUILD_VENV/bin/dmgbuild"
  if [[ -x "$dmgbuild" ]] \
    && "$DMGBUILD_VENV/bin/python3" -m pip show dmgbuild 2>/dev/null | grep -qx "Version: $DMGBUILD_VERSION"; then
    return 0
  fi
  echo "installing dmgbuild $DMGBUILD_VERSION into $DMGBUILD_VENV"
  rm -rf "$DMGBUILD_VENV"
  python3 -m venv "$DMGBUILD_VENV" \
    && "$DMGBUILD_VENV/bin/python3" -m pip install --quiet --disable-pip-version-check "dmgbuild==$DMGBUILD_VERSION"
}

rm -f "$dmg_path"
if ensure_dmgbuild; then
  "$DMGBUILD_VENV/bin/dmgbuild" \
    -s "$SCRIPT_DIR/dmg-settings.py" \
    -D app="$APP_PATH" \
    "$volume_name" \
    "$dmg_path"
else
  echo "warning: dmgbuild unavailable, falling back to a plain hdiutil image" >&2
  staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/nulconnect-dmg.XXXXXX")"
  cleanup() {
    rm -rf "$staging_dir"
  }
  trap cleanup EXIT

  cp -R "$APP_PATH" "$staging_dir/"
  ln -s /Applications "$staging_dir/Applications"
  hdiutil create \
    -volname "$volume_name" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"
fi

echo "done: $dmg_path"
