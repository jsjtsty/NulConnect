# NulConnect

[![CI](https://github.com/jsjtsty/NulConnect/actions/workflows/ci.yml/badge.svg)](https://github.com/jsjtsty/NulConnect/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPLv3-blue.svg)](LICENSE)

NulConnect is a native macOS client for compatible secure access services. It provides an interactive desktop interface for authentication, session management, resource inspection, proxy access, and system-wide tunnel access.

## Features

- Native SwiftUI application for macOS
- Password, SMS, and web-based callback authentication flows
- Persistent session storage and session resumption
- Local proxy mode with optional macOS system-proxy integration
- VPN/TUN mode for system-wide traffic routing
- Resource and DNS snapshot handling
- Privileged helper management for tunnel and proxy operations
- arm64 and x86_64 macOS builds
- Automated CI builds and tag-based GitHub Releases

The application delegates protocol, authentication, resource, and transport operations to the [libreatrust](https://github.com/jsjtsty/libreatrust) Rust library. Privileged platform operations are handled by [nulconnect-helper](https://github.com/jsjtsty/nulconnect-helper).

## Requirements

- macOS 14.0 or later
- Xcode with a macOS SDK suitable for the deployment target
- Network access to download the prebuilt Rust dependencies during the first build

Both Apple Silicon and Intel macOS builds are supported. The application requires administrator authorization when installing or updating its privileged helper.

## Build locally

The Rust dependencies are downloaded from their GitHub Releases; they are not committed to this repository.

```bash
git clone https://github.com/jsjtsty/NulConnect.git
cd NulConnect

# Use arm64 on Apple Silicon, or x86_64 for an Intel build.
scripts/update-dependencies.sh --arch arm64

xcodebuild \
  -project NulConnect.xcodeproj \
  -scheme NulConnect \
  -configuration Release \
  -sdk macosx \
  -arch arm64 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

Opening `NulConnect.xcodeproj` in Xcode also runs the dependency preparation phase automatically. The compatibility command `scripts/update-vendor-libs.sh` delegates to the new dependency downloader.

## Dependencies

The application currently consumes prebuilt artifacts from these projects:

- [libreatrust v0.2.4](https://github.com/jsjtsty/libreatrust)
- [nulconnect-helper v0.2.4](https://github.com/jsjtsty/nulconnect-helper)

Downloaded files are stored under `.build/`, which is ignored by Git. The versions can be overridden when testing another compatible release:

```bash
LIBREATRUST_VERSION=v0.2.4 \
NULCONNECT_HELPER_VERSION=v0.2.4 \
scripts/update-dependencies.sh --arch arm64
```

## Packaging

The existing script creates a distributable DMG from a built application bundle:

```bash
scripts/make-dmg.sh build/Release/NulConnect.app dist
```

Pushes to `main` and pull requests produce CI DMG artifacts for both supported architectures. Version tags produce GitHub Release DMG assets.

## License

NulConnect is licensed under the GNU Affero General Public License v3.0. See [LICENSE](LICENSE).
