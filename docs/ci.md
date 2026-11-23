# 用 GitHub Actions 编译和发布

仓库里有两个工作流：

| 工作流 | 什么时候跑 | 做什么 |
| --- | --- | --- |
| [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) | push 到 `main`、PR、手动 | 跑 `Packages/ReaderCore` 的 `swift test`，再用和 Release 相同的脚本归档、打包未签名 IPA（Artifacts 里的 `Chaiyue-unsigned-ipa`） |
| [`.github/workflows/release.yml`](../.github/workflows/release.yml) | 推送 `v` 开头的 tag、手动 | 下载语音框架、生成工程、归档并打包**未签名 IPA**，发布到 GitHub Release |

两个工作流都在 `macos-15` 上跑，会自动挑选镜像里最新的 Xcode 26。语音框架按 `App/Tools/fetch_kokoro.sh` 的内容做缓存，脚本没改就不会重复下载。

## 发一个版本

```sh
git tag v0.1.1
git push origin v0.1.1
```

推送后打开仓库的 **Actions → Release**。完成后 **Releases** 里会出现：

- `Chaiyue-0.1.1-unsigned.ipa`：未签名安装包
- `Chaiyue-0.1.1-dSYMs.zip`：调试符号，用来符号化崩溃日志
- `SHA256SUMS.txt`：校验和
- `INSTALL.txt`：安装说明

版本号取自 tag（去掉开头的 `v`），`CFBundleVersion` 用 Actions 的运行序号，所以同一个版本重复跑也不会撞 build 号。

也可以在 Actions 页面手动运行 Release，填一个 `0.1.0` 这样的版本号；不填就用 `App/project.yml` 里的 `MARKETING_VERSION`。手动运行会创建（或覆盖）对应的 tag 和 Release。

## 安装未签名 IPA

未签名包不能直接装，需要用自己的 Apple ID 重签：

- **AltStore / Sideloadly**：把 IPA 拖进去，登录自己的 Apple ID 后安装（免费账号 7 天有效，开发者账号 1 年）。
- **TrollStore**：支持的系统可以直接装。
- **Xcode**：打开工程，在 Signing & Capabilities 里选自己的开发团队，连上手机直接运行。

校验下载是否完整：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

## 本地复现同样的编译

需要 macOS、Xcode 26、[XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```sh
brew install xcodegen
bash App/Tools/fetch_kokoro.sh --frameworks-only   # 只下编译用的框架，不下几百 MB 的语音模型
bash App/Tools/build_ipa.sh 0.1.0 1                # 产物在 dist/
```

`build_ipa.sh` 会自己重新生成 `App/Chaiyue.xcodeproj`，然后用 `CODE_SIGNING_ALLOWED=NO` 归档，所以不需要证书。只跑阅读核心的测试：

```sh
swift test --package-path Packages/ReaderCore
```

## 想发布到 TestFlight / App Store 的话

未签名包是为了不依赖 Apple 开发者账号也能持续出包。如果要上传 TestFlight，需要在仓库 Secrets 里配置签名材料，再加一个签名 + 上传的 job：

| Secret | 内容 |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Apple Distribution 证书 `.p12` 的 base64 |
| `P12_PASSWORD` | 上面 `.p12` 的密码 |
| `PROVISIONING_PROFILE_BASE64` | App Store 描述文件的 base64 |
| `KEYCHAIN_PASSWORD` | CI 临时钥匙串的密码（随便设） |
| `APPLE_TEAM_ID` | 开发者 Team ID |
| `APPSTORE_API_KEY_ID` / `APPSTORE_API_ISSUER_ID` / `APPSTORE_API_PRIVATE_KEY` | App Store Connect API Key，用于上传 |

需要的话可以在 `release.yml` 里加一个 `testflight` job，复用 `App/Tools/build_ipa.sh` 的归档步骤，改成手动签名后 `xcodebuild -exportArchive` 导出，再用 `xcrun altool` 或 `fastlane pilot` 上传。

## 备注

- 公开仓库的标准 macOS 运行器不计费；私有仓库会消耗 Actions 分钟数。
- 工作流固定在 `macos-15`，如果以后镜像里没有 Xcode 26，会直接报错提醒，不会悄悄用旧 SDK 编出有问题的包。
- 发版只依赖 tag，不需要改 `project.yml` 里的版本号；想在本机 Xcode 里看到新版本号时再改。
