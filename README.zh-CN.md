# NulConnect

[![CI](https://github.com/jsjtsty/NulConnect/actions/workflows/ci.yml/badge.svg)](https://github.com/jsjtsty/NulConnect/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPLv3-blue.svg)](LICENSE)

[English](README.md) | 简体中文

NulConnect 是 **深信服 aTrust**（零信任接入服务）的第三方开源 macOS 客户端。它提供原生桌面界面，用来登录 aTrust 服务端、管理会话，并通过本地代理或全局隧道访问服务端发布的内部资源。

> **声明：** 本项目为非官方项目，与深信服科技无隶属、认可或支持关系。“aTrust”“深信服”是其各自所有者的商标。请仅用于你有权访问的服务。

## 功能

- 原生 SwiftUI macOS 应用
- 密码、短信和 Web 回调登录
- 会话持久化与恢复
- 本地代理模式，可选自动设置 macOS 系统代理
- VPN/TUN 模式，全局接管流量
- 资源和 DNS 快照处理
- 特权辅助程序管理，负责隧道和代理操作
- 仅隧道传输 IPv4，访问 IPv6 目标时直连
- 支持 arm64 和 x86_64 的 macOS 构建
- 自动化 CI 构建，标签触发 GitHub Release

应用把 aTrust 的协议、认证、资源和传输交给 Rust 库 [libreatrust](https://github.com/jsjtsty/libreatrust) 处理，特权平台操作由 [nulconnect-helper](https://github.com/jsjtsty/nulconnect-helper) 完成。

## 系统要求

- macOS 14.0 或更高版本
- 带有符合部署目标的 macOS SDK 的 Xcode
- 首次构建时需要联网下载预编译的 Rust 依赖

Apple 芯片和 Intel 的 macOS 都支持。安装或更新特权辅助程序时，应用需要管理员授权。

## 本地构建

Rust 依赖从各自的 GitHub Release 下载，不提交在本仓库中。

```bash
git clone https://github.com/jsjtsty/NulConnect.git
cd NulConnect

# Apple 芯片用 arm64，Intel 用 x86_64。
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

在 Xcode 中打开 `NulConnect.xcodeproj` 时也会自动运行依赖准备步骤。兼容命令 `scripts/update-vendor-libs.sh` 会转调新的依赖下载脚本。

## 依赖

应用目前使用以下项目的预编译产物：

- [libreatrust v0.3.4](https://github.com/jsjtsty/libreatrust)
- [nulconnect-helper v0.3.2](https://github.com/jsjtsty/nulconnect-helper)

下载的文件存放在 `.build/` 下，已被 Git 忽略。测试其他兼容版本时可以覆盖版本号：

```bash
LIBREATRUST_VERSION=v0.3.4 \
NULCONNECT_HELPER_VERSION=v0.3.2 \
scripts/update-dependencies.sh --arch arm64
```

## 打包

打包脚本会用构建好的应用包生成可分发的 DMG。首次使用时它会把 [dmgbuild](https://github.com/dmgbuild/dmgbuild) 安装到 `.build/dmgbuild-venv`，所以只需要 `python3`：

```bash
scripts/make-dmg.sh build/Release/NulConnect.app dist
```

推送到 `main` 和拉取请求会产出两种架构的 CI DMG 构件，版本标签会产出 GitHub Release 的 DMG 资源。

## 许可证

NulConnect 使用 GNU Affero General Public License v3.0 许可。见 [LICENSE](LICENSE)。
