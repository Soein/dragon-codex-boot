# macOS 安全与发布

两套启动器只接受官方 Codex 身份 `com.openai.codex`，并验证 Apple Developer ID 签名及 OpenAI Team ID `2DC432GLL2`。配置版的 `AppPath` 可以选择官方 App 的其他安装位置，不能更改允许的应用身份。进程名称、显示名或相同 Bundle Identifier 都不能单独证明应用来自 OpenAI。

## 当前用户安装

`install-codex-integration.sh` 与 `uninstall-codex-integration.sh` 默认使用当前用户的 `~/Applications` 和 `~/Library/LaunchAgents`，拒绝 root，不调用 `sudo`。在构建或调用 `launchctl` 前，检查用户目录、Applications、Library、LaunchAgents 的每一层父目录，以及 App、Contents、MacOS、Info.plist、主可执行文件和目标 plist 的文件类型。符号链接（含悬空链接）、目录位置上的普通文件和不匹配的 App 元数据均会拒绝。

安装验证源 App 完整签名，将它复制到 Applications 下新建的临时目录，再次验签后整包替换；失败时清理暂存，替换后续步骤失败会恢复原 App 和 plist。旧版额外资源不会保留到新包。卸载直接移除固定位置的已知 App 与 plist，不执行可被当前用户修改的旧二进制。用户的配置与复制后的视频会保留。

脚本处理路径误配置和预先放置的链接，不提供抵御同一用户在检查与操作之间主动改动目录的隔离边界。`--user-root /absolute/directory` 可显式选择当前用户所有的目录以便测试，不修改 `HOME`；常规安装无需使用此参数。安装测试以 `/private/tmp` 为根并替换 `launchctl`，不注册真实登录项。

## 本地与正式发布

| 模式 | 签名与产物 |
| --- | --- |
| `--mode local`（默认） | 本机 ad hoc 签名与完整性检查，ZIP 沿用现有名称。它不能证明发布者身份，也不包含 Apple 公证。 |
| `--mode release` | 指定 Developer ID Application 身份、Hardened Runtime、安全时间戳、Apple 公证、票据装订及验证，最终 ZIP 名称含 `-notarized`。 |

两种 App 共用 `package-macos.sh`，通过 `--variant standalone`（默认）或 `--variant integration` 选择。`package-macos-standalone.sh` 保留为独立版入口。构建脚本也接受签名模式参数，但只有打包入口完成公证与最终 ZIP 生成。

正式模式需由发布者事先准备：

- 钥匙串中可用的完整 Developer ID Application 签名身份及其私钥。
- `notarytool` 的现有 Keychain Profile。
- 可访问 Apple 签名时间戳与公证服务的网络，以及可用的 Apple 开发工具。

通过 `--identity 'Developer ID Application: YOUR NAME (TEAMID1234)'` 和 `--notary-profile PROFILE` 指定，或分别设置 `MACOS_SIGNING_IDENTITY`、`MACOS_NOTARY_PROFILE`。脚本不创建证书、不查找或导出私钥，也不自动保存公证凭据。不要把密钥、密码或凭据文件提交到仓库。

正式签名后，脚本验证 Apple 信任链、Developer ID Application 证书类型、完整证书名称、Team ID、Hardened Runtime 和时间戳。先生成临时提交 ZIP，以 `notarytool submit --wait --output-format plist` 等待结果，且仅接受 `Accepted`；随后对 App 执行 `stapler staple`、`stapler validate`，再次验签，再生成最终 ZIP 和 SHA-256。ZIP 本身不能装订票据，因此最终 ZIP 必须在 App 装订之后重新生成。任何失败都会非零退出，没有 ad hoc 回退。

## 验证边界

```sh
./scripts/test-macos-install.sh
./scripts/test-macos-release.sh
./scripts/test-macos-signature-requirement.sh
./scripts/test-macos.sh
./scripts/test-macos-standalone.sh
```

路径回归使用真实文件系统、App 元数据和本机签名，覆盖恶意路径、整包替换、失败保护和卸载不执行旧代码。发布回归先拒绝真实 ad hoc 签名，再以隔离替身覆盖凭据缺失、签名失败、缺少 Hardened Runtime 或时间戳、公证命令失败、公证拒绝、装订与票据验证失败；它不会实际上传 Apple。签名规则测试通过系统签名 `/bin/echo` 的正反例校验生产规则调用；系统证书信任服务必须可访问。可额外设置 `MACOS_TEST_DEVELOPER_ID_APP` 和已独立核实的 `MACOS_TEST_DEVELOPER_ID_IDENTITY`，检查真实 Developer ID App 的发布规则。

未具备发布凭据时，真实 Developer ID 签名、Apple 公证、离线 Gatekeeper 首次启动和其他机器上的分发体验仍需发布者验证。本机构建或离线替身测试通过，均不能写作“已公证”。

流程依据 Apple 官方[公证前提](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)与[自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)，以及本机 `codesign`、`notarytool submit --help`、`stapler --help`。文档与命令格式核对日期：2026-10-30。
