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
