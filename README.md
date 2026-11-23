<p align="center">
  <b>English</b> · <a href="README.zh.md">简体中文</a>
</p>

<h1 align="center">DSH Go Lite</h1>

<p align="center">
  A smaller <a href="https://github.com/ccch1mneyyy/dsh-go">DSH Go</a>: DeepSeek Harness on your Android phone, and on the computers you already run it on. Built on <a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a>. Not an official DeepSeek app.
</p>

<p align="center">
  <img alt="Android 8+" src="https://img.shields.io/badge/Android-8%2B-4B67B4?style=flat-square&logo=android&logoColor=white&labelColor=2B3245">
  <a href="LICENSE"><img alt="License AGPL-3.0" src="https://img.shields.io/badge/license-AGPL--3.0-4B67B4?style=flat-square&labelColor=2B3245"></a>
</p>

## What this is

A fork of DSH Go with the community and entertainment features removed, and the engine runtime moved into its own repository, [DSH-Go-Lite-Runtime](https://github.com/xinkev/DSH-Go-Lite-Runtime), which this repository includes as the `runtime/` submodule.

## What is different from DSH Go

| | DSH Go | DSH Go Lite |
| --- | --- | --- |
| Chat, tools, approvals, questions | yes | yes |
| Local runtime on the phone (Ubuntu, Node.js, DSH) | yes | yes |
| Remote hosts: SSH, dsh-pocket QR, own URL | yes | yes |
| Official web interface inside the app | yes | yes |
| Phone control (screen reading, taps) | yes | yes |
| Themes, icons, 中文 and English | yes | yes |
| Pets and companions | yes | no |
| Forum and community pages | yes | no |
| DS Bot | yes | no |
| Media generation | yes | no |
| Voice input and live captions (sherpa) | yes | no |
| Creative workshop, plugin market | yes | no |
| Engine runtime and release publishing | in this repository | [its own repository](https://github.com/xinkev/DSH-Go-Lite-Runtime) |

## Install

Android 8 or newer, arm64. There is no published Lite release yet; build the APK from source:

```bash
git clone --recursive <this repository>
cd app && flutter pub get
cd .. && tooling/build-apk.sh --no-companion
```

The APK lands in `app/build/app/outputs/flutter-apk/`. The script embeds the published runtime layers; `--with-runtime` and `--no-runtime` change that.

## First run

1. Install the local runtime from the app ("Install runtime"), or skip it and connect to a computer.
2. Sign in with a DeepSeek account, paste a DeepSeek API key, or add another provider with its own Base URL and key.
3. For a remote host, open 远程主机 and scan the QR code from dsh-pocket, then enter its PIN.

## Documentation

- [Architecture](docs/architecture.md) · [Contributing](CONTRIBUTING.md) · [User guide](docs/guide/README.md)
- [Runtime repository](https://github.com/xinkev/DSH-Go-Lite-Runtime): build recipe, engine patches, release publishing

The user guide still describes the original app in places; features listed as removed above are not in this build.

## Credits and licence

DSH Go Lite is a fork of [DSH Go](https://github.com/ccch1mneyyy/dsh-go) by ccch1mneyyy, which is built on [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness). Licensed under the AGPL-3.0; see [LICENSE](LICENSE). DeepSeek names and marks belong to their owners.
