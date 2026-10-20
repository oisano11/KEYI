---
id: keyi-windows-app
type: module-design
title: KEYI.Windows — Windows 托盘应用与 UIA 写回
status: draft
parent: keyi-architecture
tags:
  - module
  - windows
---

# KEYI.Windows — Windows 托盘应用与 UIA 写回

## 职责

Windows 版的全部平台交互：托盘图标与菜单、全局快捷键、UI Automation 读写焦点输入框、设置与凭据、
单实例。它取代了 macOS 的菜单栏形态，但保持同一套产品行为（见 [keyi](keyi)）。

## 拥有的东西

- **生命周期与单实例**（`Program.cs`）：命名互斥量 `Local\KEYI.InputTranslator`；抢不到即静默退出。
  之后初始化 WinForms 并以 `Application.Run()` 常驻，无主窗口。
- **托盘与编排**（`AppController`）：`NotifyIcon` 菜单承载提供方、目标语言、场合、风格、界面语言、
  当前快捷键、立即翻译、设置、重设快捷键、版本说明、退出；`TranslateFromTrayAsync` 是快捷键与菜单
  共用的唯一入口，用 `_busy` 防止重入。
- **焦点文本读写**（`FocusedTextClient`）：按 `FocusedTextReadModePolicy` 选模式 ——
  TextPattern（能读选区与全文）、ValuePattern（只能读全文）、ClipboardSelection（仅微信、
  WhatsApp 白名单）。写回前用前台窗口句柄加 UIA `RuntimeId` 复核目标，再核对原文与选区。
- **剪贴板降级**：复制取文时最多尝试 20 次、间隔 25ms，并用剪贴板序列号与所有者确认这次变化确实来自
  目标进程；写回后用最多 40 次、间隔 50ms 的读回验证确认内容落地。剪贴板原内容在结束时恢复。
- **全局快捷键**（`GlobalHotKeyManager`、`HotKeyConfigurationForm`）：注册系统热键，冲突时保留旧配置
  并提示，而不是留下没有快捷键的状态。
- **设置与凭据**（`SettingsForm`、`SettingsStore`、`CredentialStore`、`UiStrings`）：四个提供方的
  密钥（DeepSeek、Qwen、Volcengine、XAI）存 Windows Credential Manager；其余偏好存
  `%LocalAppData%\KEYI\settings.json`。界面文案集中在中英两套 `UiStrings`。

## 边界

- 只依赖 `KEYI.Core` 与 .NET／WinForms／UIA；翻译语义与提示词不在这里复制。
- 不做 Apple 系统翻译，也不做本地模型 —— 两者在 Windows 上没有可信的等价物。
- 不跨平台共享二进制；产品契约共享，实现不共享。

## 已知边界（已确认）

- **需要 UI Automation。** 输入框必须支持 TextPattern 或 ValuePattern；两者都不支持的控件直接报
  「该控件不支持文本」，不做盲目按键模拟。
- **权限必须一致。** Windows 默认禁止普通权限进程向管理员权限窗口发送输入；KEYI 以 `asInvoker`
  运行，所以与目标应用必须同权限级。
- **微信等 Qt 自绘控件走剪贴板降级，尚未完成实机验收。** 只在用户已有选区、且 UIA 读取不可用时
  临时复制读取并恢复剪贴板；没有选区时不会尝试复制全文。
- **分发仍是实验性的。** 安装器与便携程序未做 Authenticode 签名，SmartScreen 会警告，
  Windows 10/11 原生安装、升级与重启验收尚未完成。
