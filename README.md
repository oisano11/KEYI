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

## KEYI 输入法：Mac 上边打中文边翻译成英文的翻译输入法（实验）

**KEYI Pinyin — a free, open-source Chinese-to-English translation input method for macOS.
Type Chinese in pinyin, get English in place: translate as you type, no copy-paste, no hotkey.**

想在 Mac 上**打中文自动出英文**？`IME/` 是 KEYI 自带的开源 macOS 中文拼音输入法
**KEYIIME**（InputMethodKit + librime + 雾凇拼音词库）。像平常一样用拼音打字，确认的中文
就会原位换成英文——不用复制粘贴、不用切到翻译网页、也不用按翻译快捷键。适合和外国同事、
客户聊天，写英文邮件、发推、回评论，以及在微信、浏览器网页等输入框里中译英。

怎么用：

1. 用拼音正常输入，确认的中文先带下划线留在输入框里，光标旁的面板实时显示候选和中英对照预览。
2. 整段写完按**回车**，整段换成英文上屏（只换英文、**不发送**，再按一次回车才由应用发送）。
3. 想保留中文就**单按 Shift**，中文原样上屏、不翻译；密码框和安全输入里不翻译、不发请求。

为什么选它：

- **本地翻译、可离线**：自然、正式商务、贴近原文三种风格用 KEYI 自带的本地翻译模型
  （腾讯混元 Hy-MT2，设置里下载），文字不出本机；需要地道美式口语时再接你配置的大模型 API。
- **隐私边界清楚**：输入法进程本身不联网、不持有凭据，翻译由同仓库的 KEYI 可译在本机完成或转给你选的服务。
- **好用的中文拼音底子**：基于 Rime / librime 引擎与雾凇拼音（rime-ice）词库，支持中英混输。
- **开源免费**：源码、脚本、Rime 方案与词库都在本仓库，可以自己构建、审查和修改。

现状：实验版，只在作者本机日常使用；没有公证的安装包，需要从源码构建；真实应用里以 macOS 15
上的微信、浏览器、终端等常见输入框为主，其他应用可能有光标定位或回写差异。

**In English:** KEYI Pinyin is a macOS pinyin IME built on Rime (librime) with the rime-ice
dictionary. After you confirm Chinese characters, KEYI translates the whole sentence into English
and replaces it in place when you press Return — it never sends the message for you. Translation
can run fully on-device with a bundled local model (Tencent Hunyuan Hy-MT2), or through an
LLM API you configure. Useful for chatting with English speakers, writing English emails and
social posts, or anyone who thinks in Chinese but needs to write in English on a Mac.
Experimental; build from source (macOS 15+).

从源码构建与安装（需要 macOS 15+）：

```sh
Scripts/build-app.sh                      # KEYI 可译（翻译服务在它里面）
IME/Scripts/build-ime.sh release          # 输入法
IME/Scripts/install-ime.sh release        # 装到 ~/Library/Input Methods，不自动启用
```

然后在「系统设置 → 键盘 → 文字输入 → 编辑…」添加「简体中文 → KEYI 拼音」。用法、检查和
词库许可见 [IME/README.md](IME/README.md)；雾凇拼音词库保留其上游 GPL-3.0 等许可，见
[IME/THIRD_PARTY_NOTICES.md](IME/THIRD_PARTY_NOTICES.md)。

## Quick Start / 快速开始

### macOS：安装实验 DMG

当前实验版提供 Apple Silicon（arm64）DMG。打开 DMG 后，将“KEYI 可译”拖到 `Applications`，再从“应用程序”打开。

#### 第一次打开

1. 本实验版使用本机开发签名，未经过 Apple 公证。若 macOS 提示无法验证开发者，在 Finder 中按住 Control 点按“KEYI 可译”，选择“打开”。
2. 若仍被拦截，先尝试打开一次，然后到“系统设置 → 隐私与安全性”底部选择“仍要打开”，再重新打开应用。不要关闭 Gatekeeper 或执行来历不明的终端命令。
3. 打开 KEYI 的“设置 → 通用”，授予“辅助功能”权限；也可在“系统设置 → 隐私与安全性 → 辅助功能”中启用 KEYI 可译。授权后退出并重新打开 KEYI。

#### 使用系统翻译

系统翻译不需要 API Key。在“设置 → 翻译服务”选择“系统翻译”，再选择目标语言。

- 第一次使用某个语言组合时，macOS 需要下载对应的翻译语言资源。保持联网，按系统提示选择下载或继续，等待下载完成后再次翻译。
- 翻译资源由 macOS 管理，KEYI 不会自行下载或保存语言包。系统未提供该语言组合、下载失败或长期无响应时，可稍后联网重试，或改用云端翻译服务。
- 系统翻译只使用目标语言，不应用 KEYI 的“使用场景”和“表达风格”。

#### 常见限制

- 密码框、只读区域和部分自绘输入框不能读取或写回文字；先在普通可编辑输入框测试。
- 翻译过程中切换窗口、移动光标或继续输入会取消写回，避免覆盖新内容。
- 更换或重新复制应用后，macOS 可能要求再次确认辅助功能权限。

### macOS：从源码构建

需要 macOS 15 或更高版本与 Xcode Command Line Tools：

```sh
Scripts/test.sh
Scripts/build-app.sh
```

构建产物为 `.build/KEYI 可译.app`。首次使用时，在“系统设置 → 隐私与安全性 → 辅助功能”中允许 KEYI 可译。

默认构建仅用于本机开发：使用本机钥匙串里的 Apple Development 证书签名（免费的 Xcode 个人团队即可生成），找不到时使用 ad-hoc 签名。两者都不能作为受支持的正式分发包。源码 Release 不需要 Apple 证书。

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

详细说明见 [Windows/README.md](Windows/README.md)。稳定的 `v1.1.6` Release 仍以源码为主；`v1.1.7-binary-preview.1` 提供 macOS DMG/ZIP 与 Windows 安装器，均为未公证或未受平台发行者信任的实验二进制，不提供自动更新或官方安装支持。

## 数据与隐私

- API Key 保存在当前用户的系统凭据存储（macOS 钥匙串、Windows 凭据管理器），不写入仓库。
- 使用云端翻译时，KEYI 可译只向你选择的服务发送待翻译文字。
- 本地模型模式可在本机使用完整输入框上下文以改善语境；该内容不离开本机。
- 本地模型是 KEYI 自带的 Hy-MT2-1.8B：由你在设置里下载并校验 sha256，KEYI 打包官方 llama.cpp `llama-server` 运行，只走本用户 UNIX socket 加随机密钥，不对外监听。
- macOS 仅从辅助功能接口读取可确认的选区；完全不暴露文本的控件不再通过剪贴板猜测来源。
- 终端替换中断后，可从 KEYI 菜单复制保留的原命令，再手动恢复；退出应用会清除尚未取回的原命令。
- 请勿在密码框、只读区域或不允许处理敏感内容的输入框中使用。

## 许可与商业合作

本项目采用 [Apache License 2.0](LICENSE.md)，允许商业使用、修改和再发布。

再发布时请保留版权声明和许可证文本；修改过的文件应注明修改。Apache-2.0 不授予 KEYI 的商标或品牌使用权。

商业合作、官方支持和定制服务咨询：oisano@icloud.com

## 社区

欢迎提交 Issue 报告问题或提出建议。首次公开阶段暂不接收 Pull Request；如有代码合作或商业服务需求，请通过合作邮箱联系。

## 状态

当前源码版本为 1.1.8，更新英语风格提示词，优先地道表达并保留原意、关系和情绪。实验二进制只用于自愿测试；Windows 10/11 真机的安装、升级、重启和签名验证仍未完成，macOS 实验包也未通过 Gatekeeper 公证。
