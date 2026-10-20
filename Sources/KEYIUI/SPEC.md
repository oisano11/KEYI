---
id: keyi-ui
type: module-design
title: KEYIUI — macOS 应用层与翻译编排
status: active
parent: keyi-architecture
tags:
  - module
  - macos
---

# KEYIUI — macOS 应用层与翻译编排

## 职责

把「按了一次快捷键」变成「输入框里的文字被替换」：管理常驻生命周期、全局快捷键、翻译状态机、
提供方调用、设置与凭据、以及结果反馈。

它是唯一允许触碰平台框架的地方 —— AppKit、Carbon（全局热键）、ApplicationServices（辅助功能）、
Translation（系统翻译）、Security（Keychain、代码签名）。

## 拥有的东西

- **生命周期**（`AppDelegate`、`KEYIApp`、`KEYI/main.swift`）：`LSUIElement` 式的辅助应用
  （`.accessory` 激活策略）+ 菜单栏项，无 Dock 图标、无主窗口。
- **单实例**（`SingleInstance`）：`KEYILauncher.run()` 在创建任何界面之前抢 `flock`，抢不到即退出。
- **全局快捷键**（`GlobalHotKey`、`HotKeyConfiguration`）：Carbon 热键注册；更换快捷键时先注册新的、
  成功后再注销旧的，避免中途留下无热键的窗口；系统唤醒／会话切换后重新注册。
- **状态机与编排**（`AppModel`）：`ready / permissionRequired / preparing / translating / success /
  failure` 六态；`preparing` 在捕获之前就置位，使重复按键无法插进剪贴板操作中间；按提供方分派到系统
  翻译、云端、本地模型三条路径；完成与失败都回到同一处收口。
- **系统翻译宿主**（`TranslationHostView`）：SwiftUI `translationTask` 必须挂在一个真实可见的视图上。
  实现是一个 1×1、`alphaValue = 0.01`、不可点击、位于屏幕外的 `NSPanel` —— 不可见但真实存在，
  既不抢焦点也不出现在截图里。**这是 Apple 翻译框架的要求，不是遗漏。**
- **反馈**（`TranslationIslandController`、`MenuBarContent`）：翻译中的浮层状态与菜单栏菜单；
  菜单里还有终端恢复命令的复制／丢弃入口。
- **设置与凭据**（`SettingsWindow`、`TranslationSettingsStore`、`CredentialStore`、
  `InterfaceLocalization`）：四个分页（翻译、服务、快捷键、通用）与中英两套界面文案；偏好存
  `UserDefaults`，密钥存 Keychain，两者分开。
- **写回**：见 [keyi-writeback](keyi-writeback)。
- **本地模型**：见 [keyi-local-model](keyi-local-model)。

## 边界

- 只依赖 `KEYICore` 与系统框架；不复制核心层的语言、场合、风格枚举 —— 那些类型直接来自核心层，
  否则菜单可用性与提示词会各说一套。
- 不实现翻译语义：如何措辞、如何判断截断，属于 [keyi-core](keyi-core)。
- 不做进程外通信、不开放网络端口、不监听除快捷键以外的输入。

## 已知约束

- 辅助功能权限由用户在系统设置里授予；未授权时状态机进入 `permissionRequired` 并引导授权，而不是静默失败。
- 系统翻译（`Translation` 框架）只接受目标语言，场合与英文风格对它无效；`activeTranslationRequest()`
  因此强制 `appleSystem` + `faithful` + `automatic`。
