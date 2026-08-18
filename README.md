# KEYI 可译

> 不用复制，不用切换；在哪里输入，就在哪里翻译。

KEYI 可译是 macOS 和 Windows 的桌面输入翻译助手。选中文字，或将光标留在当前输入框，按一次全局快捷键，即可把中文翻译成目标语言并原地写回。

它不替换系统输入法，也不会自动发送消息。你可以选择系统翻译、云端模型 API 或本地模型，并自行管理所用服务和凭据。

## 功能

- 选区优先；没有选区时翻译当前输入框全文。
- 翻译后原地替换文本，不自动发送。
- 支持 macOS 与 Windows。
- 支持英语、日语、韩语、法语、德语、西班牙语、俄语、葡萄牙语、意大利语、泰语、越南语、阿拉伯语。
- 支持全局快捷键、翻译场景与个人偏好保存。
- 云端翻译默认仅发送待翻译文本，不上传未选中的完整输入框内容。

## 快速开始

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

详细说明见 [Windows/README.md](Windows/README.md)。稳定的 `v1.1.6` Release 仍以源码为主；`v1.1.6-binary-preview.1` 是未公证/未签名的实验二进制，不提供自动更新或官方安装支持。

## 数据与隐私

- API Key 保存在当前用户的系统凭据存储（macOS 钥匙串、Windows 凭据管理器），不写入仓库。
- 使用云端翻译时，KEYI 可译只向你选择的服务商发送待翻译文字。
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
