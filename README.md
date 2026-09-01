<div align="center">
  <h1>KEYI 可译</h1>
  <p><em>In-place translation for macOS and Windows. Translate where you type.</em></p>
</div>

<p align="center">
  <a href="https://github.com/oisano11/KEYI/actions/workflows/ci.yml"><img src="https://github.com/oisano11/KEYI/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/oisano11/KEYI/releases"><img src="https://img.shields.io/github/v/release/oisano11/KEYI?display_name=tag&style=flat-square" alt="Release"></a>
  <a href="LICENSE.md"><img src="https://img.shields.io/badge/license-Apache--2.0-blue?style=flat-square" alt="License"></a>
  <a href="https://github.com/oisano11/KEYI/stargazers"><img src="https://img.shields.io/github/stars/oisano11/KEYI?style=flat-square" alt="Stars"></a>
</p>

> 不用复制，不用切换；在哪里输入，就在哪里翻译。

KEYI is an open-source desktop translator for macOS and Windows. Select text, or place the cursor in an editable input field, press a global shortcut, and the translation is written back in the same app.

KEYI 可译是 macOS 和 Windows 的桌面输入翻译工具。选中文字，或将光标留在可编辑输入框，按一次全局快捷键，即可翻译成目标语言并原地写回。

它不替换系统输入法，也不会自动发送消息。你可以选择系统翻译、云端翻译服务或本地模型，并自行管理所用服务和凭据。

**Use cases:** email, chat, documents, social posts, support replies, and any compatible text field where copy/paste interrupts your flow.

## Features / 核心能力

- **原地翻译**：优先处理选中文字；没有选区时处理当前输入框全文。结果直接写回，不会自动发送。
- **全局快捷键**：在任何支持的输入框中触发翻译，无需复制、切换到网页或粘贴回来。
- **双平台使用**：提供 macOS 菜单栏与 Windows 系统托盘入口，并保存各自的快捷键和偏好。
- **13 种目标语言**：中文、英语、日语、韩语、法语、德语、西班牙语、俄语、葡萄牙语、意大利语、泰语、越南语、阿拉伯语。
- **多种翻译服务**：macOS 可使用系统翻译；也可接入 DeepSeek、通义千问、火山方舟、Grok、自定义兼容服务或本地模型。
- **语境与表达**：模型服务可按聊天、发帖、商务或贴近原文调整翻译；目标语言为英语时可选择表达风格。系统翻译保留系统自身的语言处理方式。
- **数据边界清晰**：云端服务默认只接收待翻译文本；API Key 保存在当前用户的系统凭据存储，不写入仓库。

## How It Works

1. Open an editable text field in any supported app.
2. Select text, or leave the cursor in the field to translate its current contents.
3. Press the global shortcut (`⌥T` on macOS, `Alt+T` on Windows by default).
4. KEYI translates the text and writes the result back without sending the message.

中文：选中文字优先；没有选区时翻译当前输入框。翻译完成后直接写回原位置，不自动发送。

## Quick Start / 快速开始

### macOS

需要 macOS 15 或更高版本与 Xcode Command Line Tools：

```sh
Scripts/test.sh
Scripts/build-app.sh
```

构建产物为 `.build/KEYI 可译.app`。首次使用时，在“系统设置 → 隐私与安全性 → 辅助功能”中允许 KEYI 可译。

默认构建仅用于本机开发；没有 Apple Developer 证书时会优先使用本机开发证书（例如 `Codex++ Local Signing`），找不到时才使用 ad-hoc 签名。两者都不能作为受支持的正式分发包。源码 Release 不需要 Apple 证书。

macOS 正式二进制发布前，必须加入 Apple Developer Program，在开发者后台登记 Bundle ID `com.keyi.input-translator`，创建并安装 `Developer ID Application` 证书，然后显式执行：

```sh
KEYI_SIGNING_MODE=distribution Scripts/build-app.sh
```

该模式找不到证书会直接失败，不会静默退回 ad-hoc。签名完成后仍需使用 `notarytool` 提交公证并用 `stapler` 固化票据，才能作为受支持的公开安装包。私钥只应留在签名者或受控 CI 中，不要发送给他人。

### Windows

需要 .NET 8 SDK、NSIS 与 7-Zip：

```sh
Scripts/build-windows.sh
```

如需同时生成 macOS/Windows 实验二进制，可执行：

```sh
Scripts/package-experimental-binaries.sh
```

详细说明见 [Windows/README.md](Windows/README.md)。稳定的 `v1.1.6` Release 仍以源码为主；`v1.1.6-binary-preview.2` 提供 macOS DMG/ZIP 与 Windows 安装器，均为未公证或未受平台发行者信任的实验二进制，不提供自动更新或官方安装支持。

## 数据与隐私

- API Key 保存在当前用户的系统凭据存储（macOS 钥匙串、Windows 凭据管理器），不写入仓库。
- 使用云端翻译时，KEYI 可译只向你选择的服务发送待翻译文字。
- 本地模型模式可在本机使用完整输入框上下文以改善语境；该内容不离开本机。
- 请勿在密码框、只读区域或不允许处理敏感内容的输入框中使用。

## 许可与商业合作

本项目采用 [Apache License 2.0](LICENSE.md)，允许商业使用、修改和再发布。

再发布时请保留版权声明和许可证文本；修改过的文件应注明修改。Apache-2.0 不授予 KEYI 的商标或品牌使用权。

商业合作、官方支持和定制服务咨询：oisano@icloud.com

## 社区

欢迎提交 Issue 报告问题或提出建议。首次公开阶段暂不接收 Pull Request；如有代码合作或商业服务需求，请通过合作邮箱联系。

## 状态

当前源码版本为 1.1.6。实验二进制只用于自愿测试；Windows 10/11 真机的安装、升级、重启和签名验证仍未完成，macOS 实验包也未通过 Gatekeeper 公证。
