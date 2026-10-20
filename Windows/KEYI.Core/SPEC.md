---
id: keyi-windows-core
type: module-design
title: KEYI.Core — Windows 侧的纯逻辑核心
status: active
parent: keyi-architecture
tags:
  - module
  - windows
references:
  - keyi-english-style
---

# KEYI.Core — Windows 侧的纯逻辑核心

## 职责

Windows 版的全部可测逻辑：数据形状、提供方目录、提示词、HTTP 调用、设置文件、剪贴板事务与读取模式
判定。它不引用 WinForms、WPF 或 UI Automation，因此在没有桌面的 CI 机器上可以完整运行
（`KEYI.CoreChecks`）。

## 拥有的东西

- **数据与目录**（`Models.cs`）：`ProviderId`（DeepSeek、Qwen、Volcengine、XAI）、`ProviderCatalog`
  的默认端点与模型、目标语言、场合、英文风格、界面语言、`AppSettings` 的完整形状与默认值。
  Windows **没有** Apple 系统翻译，也没有本地模型提供方 —— 这是平台能力差异，不是待补的缺口。
- **提示词**（`TranslationPromptBuilder`）：与 macOS 同源的英文含义规则、场合与声音指引；中文目标走
  多语种分支。源文一律当作内容，不当指令。
- **HTTP 语义**（`OpenAiTranslationClient`）：OpenAI 兼容调用；失败按 `TranslationErrorKind`
  分类（`EmptySource`、`InvalidEndpoint`、`MissingApiKey`、`MissingModel`、`RequestFailed`、
  `EmptyResponse`、`InvalidResponse`、`TruncatedResponse`）。错误消息只留中性英文兜底，用户可见文案
  由 UI 层翻译。
- **设置文件**（`SettingsFileStore`）：`%LocalAppData%\KEYI\settings.json`，临时文件 + 原子替换写入；
  文件损坏时回落到默认设置而不是拒绝启动。密钥不在这里。
- **剪贴板事务**（`ClipboardTransaction`、`ClipboardCopyAttribution`）：把嵌套的剪贴板探测标记为
  同一个所有者，避免把自己的写入误认成用户的新剪贴板内容；恢复失败不得把已提交的编辑变成失败。
  未知或不同所有者不构成「复制成功」的证据。
- **读取模式判定**（`FocusedTextReadModePolicy`）：TextPattern 优先，其次 ValuePattern，最后才是
  剪贴板选区降级；只有白名单进程（微信、WhatsApp）允许这条降级。
- **配置迁移**（`VolcengineChatCompletionsMigration`）：旧版 `doubao-seed-translation-*` 配置迁移到
  chat completions 端点与模型。

## 边界

- 只依赖 BCL（`System.Text.Json`、`System.Net.Http`）。**不得**引入 `System.Windows.*`、
  `System.Windows.Automation` 或任何 WinForms/WPF 类型。
- 不认识窗口、焦点、键盘 —— 它接收快照与配置，返回文本或分类错误。
- 不读写凭据；Windows Credential Manager 属于 UI 层。

## 相关

- 英文风格的规则与 macOS 共用同一份契约：[keyi-english-style](keyi-english-style)。
