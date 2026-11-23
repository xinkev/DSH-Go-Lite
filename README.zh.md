<p align="center">
  <a href="README.md">English</a> · <b>简体中文</b>
</p>

<h1 align="center">DSH Go Lite</h1>

<p align="center">
  更小的 <a href="https://github.com/ccch1mneyyy/dsh-go">DSH Go</a>：DeepSeek Harness 跑在你的 Android 手机上，也能连你已经跑着它的电脑。基于 <a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a>，不是 DeepSeek 官方应用。
</p>

<p align="center">
  <img alt="Android 8+" src="https://img.shields.io/badge/Android-8%2B-4B67B4?style=flat-square&logo=android&logoColor=white&labelColor=2B3245">
  <a href="LICENSE"><img alt="License AGPL-3.0" src="https://img.shields.io/badge/license-AGPL--3.0-4B67B4?style=flat-square&labelColor=2B3245"></a>
</p>

## 这是什么

DSH Go 的分支：去掉社区和娱乐功能，并把引擎运行时独立成 [DSH-Go-Lite-Runtime](https://github.com/xinkev/DSH-Go-Lite-Runtime)，本仓库以 `runtime/` 子模块引入。

## 与原版 DSH Go 的区别

| | DSH Go | DSH Go Lite |
| --- | --- | --- |
| 对话、工具、审批、提问 | 有 | 有 |
| 手机本地运行时（Ubuntu、Node.js、DSH） | 有 | 有 |
| 远程主机：SSH、dsh-pocket 扫码、自有 URL | 有 | 有 |
| App 内的官方网页版 | 有 | 有 |
| 手机操控（读屏、点击） | 有 | 有 |
| 主题、图标、中文与英文 | 有 | 有 |
| 宠物与伙伴 | 有 | 无 |
| 论坛与社区页 | 有 | 无 |
| DS Bot | 有 | 无 |
| 媒体生成 | 有 | 无 |
| 语音输入与实时字幕（sherpa） | 有 | 无 |
| 创意工坊、插件市场 | 有 | 无 |
| 引擎运行时与发布 | 在本仓库 | [独立仓库](https://github.com/xinkev/DSH-Go-Lite-Runtime) |

## 安装

Android 8 及以上，arm64。Lite 还没有发布的安装包，请自行构建：

```bash
git clone --recursive <本仓库>
cd app && flutter pub get
cd .. && tooling/build-apk.sh --no-companion
```

APK 在 `app/build/app/outputs/flutter-apk/`。脚本会嵌入已发布的运行时；`--with-runtime` 和 `--no-runtime` 可改这一点。

## 首次使用

1. 在 App 里「安装运行时」，或跳过它直接连电脑。
2. 用 DeepSeek 账号登录、填 DeepSeek API Key，或自己添加一个服务商（Base URL 与 Key）。
3. 连远程主机：打开「远程主机」，扫描 dsh-pocket 的二维码，再输入 PIN。

## 文档

- [架构](docs/architecture.md) · [贡献](CONTRIBUTING.md) · [用户指南](docs/guide/README.md)
- [运行时仓库](https://github.com/xinkev/DSH-Go-Lite-Runtime)：构建配方、引擎补丁、发布

用户指南仍有部分内容描述原版 App；上面标为移除的功能不在本构建里。

## 致谢与许可

DSH Go Lite 是 ccch1mneyyy 的 [DSH Go](https://github.com/ccch1mneyyy/dsh-go) 的分支，后者基于 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)。以 AGPL-3.0 许可发布，见 [LICENSE](LICENSE)。DeepSeek 名称与商标归其所有者。
