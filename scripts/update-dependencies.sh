#!/bin/bash
set -euo pipefail

# Local developer entry point. Dependencies are downloaded from GitHub
# Releases and staged under .build; no Rust toolchain or Vendor directory is
# needed.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/prepare-dependencies.sh" "$@"
