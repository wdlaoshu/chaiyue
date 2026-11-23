# 在本机运行柴阅

在 macOS 上使用 Xcode 26 和 XcodeGen。首次编译需要下载 sherpa-onnx、ONNX Runtime 和 Kokoro 语音模型；脚本会校验两个框架压缩包的 SHA-256。

```sh
bash App/Tools/fetch_kokoro.sh
(cd App && xcodegen generate)
open App/Chaiyue.xcodeproj
```

在 Xcode 里选择 Chaiyue 和 iPhone 模拟器，再运行。装到真机时，先在 Signing & Capabilities 选择自己的开发团队和 Bundle Identifier。

只跑阅读核心的测试，不需要下载语音模型：

```sh
swift test --package-path Packages/ReaderCore
```

使用外部书源样本的集成测试在没有样本时会跳过。仓库不附带第三方书源或用户数据。

## 在 GitHub 上编译发布

推送 `v` 开头的 tag（如 `v0.1.0`）会自动编译未签名 IPA 并发布到 Releases。工作流说明和本机复现命令见 [docs/ci.md](docs/ci.md)。
