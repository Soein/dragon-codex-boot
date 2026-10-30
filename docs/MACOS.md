# macOS 版

macOS 版是 `macos/` 下的 Swift 原生启动器，要求 macOS 13 或更新版本以及 Swift 5.9 以上。直接打开启动器时，它使用系统 `AVKit` 播放本地 MP4、启动 `com.openai.codex`，并在可配置的等待点暂停。

## 从 Codex 图标启动动画

在仓库根目录构建并安装可选的启动监视器：

```sh
./scripts/install-codex-integration.sh
```

脚本把 `DragonCodexBoot.app` 安装到 `~/Applications/`，并在当前用户的 `~/Library/LaunchAgents/` 注册登录监视器。它会在当前会话启动，并在之后登录时自动运行；可在“系统设置 → 通用 → 登录项”停用。监视器只等待配置中 Codex Bundle Identifier 对应的新进程；从原 Codex 图标启动后，它等待 Codex 的可见主窗口出现，再按窗口边界播放动画。已运行的 Codex 被再次激活时不会重播。

安装和卸载均以当前用户运行，不使用 `sudo`。脚本在构建和操作 LaunchAgent 之前检查目标路径；遇到符号链接、普通文件占用目录或不属于本项目的 App 会拒绝。安装先复制到临时 App 并验证完整签名，再替换旧 App，避免向符号链接目标写入和混入旧版本文件。卸载直接移除已知 App 与 plist，不运行旧 App 中的代码。

动画窗口会与 Codex 窗口的位置和尺寸一致，使用 12 pt 连续圆角，四角透明并显示下方 Codex 窗口。视频按填充模式显示以消除黑边，因此当 Codex 窗口与视频宽高比不同时，会裁掉视频边缘。动画结束或按 `Esc` 后，焦点交还给 Codex。实现只读取系统提供的窗口位置和尺寸，不申请屏幕录制或辅助功能权限；不替换或修改官方 Codex App，也不接管 Dock 图标。

移除监视器和安装的启动器：

```sh
./scripts/uninstall-codex-integration.sh
```

这会保留 `~/Library/Application Support/DragonCodexBoot/` 中的配置和视频。若要再次使用，重新运行安装脚本即可。

## 功能边界

- 直接打开启动器时仍使用全屏播放；从 Codex 图标触发时使用 Codex 当前窗口的边界。
- 它不把真实 Codex 窗口实时裁切到动画里的屏幕矩形。Windows 版对应效果依靠 DWM 缩略图，macOS 没有相同的无权限接口。
- 启动器不会改写 Dock、Launch Services 或 Codex App。可选监视器只增加当前用户的 LaunchAgent，用户可在系统设置中停用或通过卸载脚本移除。
- `AppBundleIdentifier` 固定为官方 `com.openai.codex`，留空时采用该值，其他值会被拒绝。`AppPath` 可指定官方 Codex 的自定义安装位置，例如 `/Applications/Codex.app`；它不能切换到其他应用身份。启动及监视交接还会检查 Apple Developer ID 签名、OpenAI Team ID `2DC432GLL2` 和实际进程身份，应用显示名不作为身份依据。
- 配置位于 `~/Library/Application Support/DragonCodexBoot/`；首次运行会从 App 包复制配置模板。MP4 在该目录下的 `media/startup.mp4`，也可在配置里填绝对路径。启动信息写入 macOS Console。
- 构建脚本会把 `media/startup.mp4` 和 `media/MEDIA_NOTICE.md` 一并装进 App；首次运行时复制到用户配置目录。

## 构建

在仓库根目录运行：

```sh
./scripts/build-macos.sh
```

生成的 App 位于 `build/DragonCodexBoot.app`。脚本使用 `swiftc` 和本机 SDK，无需安装第三方依赖。构建结果使用本机 ad hoc 签名，仅用于本机检查；公开分发还需要 Developer ID 签名与 notarization。

本机构建可显式写为 `./scripts/build-macos.sh --mode local`。正式分发使用现有打包入口的 integration 变体：

```sh
./scripts/package-macos.sh --variant integration --mode release \
  --identity 'Developer ID Application: YOUR NAME (TEAMID1234)' \
  --notary-profile YOUR_EXISTING_PROFILE
```

该命令要求钥匙串中已存在对应 Developer ID Application 证书及私钥，以及 `notarytool` 凭据配置。它启用 Hardened Runtime 和安全时间戳，等待 Apple 公证成功并装订、验证票据后，才生成 `dist/DragonCodexBoot-版本-macos-架构-integration-notarized.zip` 与 SHA-256。缺少凭据、签名不符、公证拒绝或装订失败均停止，不回退到 ad hoc。命令会向 Apple 提交产物；本仓库的离线测试不会提交。完整流程及验证边界见 [安全与发布](MACOS-SECURITY.md)。

首次运行后，把自己的 H.264/AAC MP4 放到：

```text
~/Library/Application Support/DragonCodexBoot/media/startup.mp4
```

编辑同目录的 `launcher.json`，按视频修改 `HoldAt`、`TransitionStart`、`TransitionEnd`、`Volume`。如 Codex 未被自动找到，可在 `AppPath` 填写官方 Codex App 的实际安装路径；应用身份仍固定为 `com.openai.codex`。

## 验证

```sh
./scripts/test-macos.sh
./scripts/test-macos-install.sh
./scripts/test-macos-release.sh
```

该脚本检查 Swift 编译、配置校验、淡出曲线、App 与登录监视器清单、本机签名及随包媒体。它不注册登录监视器、不启动 Codex，也不验证窗口匹配和焦点交接；这些行为需要在安装了 Codex 的 macOS 桌面上手动确认。完整 Xcode 环境下也可运行 `swift test --package-path macos` 执行单元测试。

安装回归只使用 `/private/tmp` 夹具和替身 LaunchAgent 命令，不修改用户配置；发布回归检查本机签名拒绝与离线公证失败流程，不证明真实公证成功。

## 独立轻量版

PR #3 的独立实现保留于 `src/macos/`，不安装 LaunchAgent、不读取 `launcher.json`，使用单独的 `build-macos-standalone.sh` / `test-macos-standalone.sh`。打包入口为 `package-macos.sh`。输出 `build/macos/Dragon Codex Boot.app`，不会覆盖本页的 `build/DragonCodexBoot.app`。见 [独立版说明](MACOS-STANDALONE.md)。
