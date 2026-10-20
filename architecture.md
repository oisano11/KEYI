---
id: keyi-architecture
type: architecture-design
title: KEYI 的架构拓扑与跨平台不变量
status: active
parent: keyi
tags:
  - architecture
---

# KEYI 的架构拓扑与跨平台不变量

## 形状

两套原生实现共享同一份产品契约（见 [keyi](keyi)），不共享源代码：macOS 用 Swift，Windows 用 C#。
各自一条三层依赖链，方向唯一：

```text
macOS:    KEYI (可执行入口) ──▶ KEYIUI ──▶ KEYICore
Windows:  KEYI.Windows (托盘应用) ──▶ KEYI.Core
```

- **核心层不碰系统 UI。** `KEYICore` 只 import Foundation；`KEYI.Core` 只依赖 BCL。两者承载纯逻辑：
  选区模型、提示词、提供方目录、HTTP 语义、设置文件格式。
- **应用层承担一切平台交互**：辅助功能读写、全局快捷键、菜单栏／托盘、设置窗口、凭据库、签名校验、
  单实例。平台的差异止步于此，不向上泄漏。
- **入口是薄壳。** macOS 的 `KEYI` target 只有 `KEYILauncher.run()`，负责单实例锁与启动。

## 依赖边

跨层依赖只有一条：应用层 → 核心层。核心层永不 import 应用层；两个平台之间没有编译期依赖。

这条边是真实约束而非风格偏好：核心层的单元检查（`KEYICoreChecks`、`KEYI.CoreChecks`）在无 GUI 的
CI 机器上运行，一旦核心层触碰 AppKit／UIA，这些检查就无法执行。

## 运行时拓扑

```text
全局快捷键 ──▶ AppModel（唯一状态机）──▶ 提供方 ──▶ 译文
                    │
                    ▼
            AccessibilityTextClient（捕获快照 / 按快照写回）
                    │
                    ▼
              目标应用的原输入框
```

一次翻译是一个**快照事务**：捕获时记下目标身份的完整证据（窗口、父节点、identifier、role）、原始
全文、原始选区、写入模式；写回前逐项复核，任一不符即取消。写回不是「把文本发过去」，而是「证明还是
那个位置，然后替换」。

## 跨平台不变量

- **单实例。** macOS 用 `flock` 独占 `~/Library/Application Support/com.keyi.input-translator/instance.lock`；
  Windows 用命名互斥量 `Local\KEYI.InputTranslator`。锁文件永不删除 —— 删掉一个被持有的锁文件会让
  另一个进程锁到不同 inode，单实例失效。
- **版本三处一致。** 版本号只有一个来源：`Windows/KEYI.Windows/KEYI.Windows.csproj` 的 `<Version>`；
  `AppBundle/Info.plist` 的 `CFBundleShortVersionString`／`CFBundleVersion` 与
  `Windows/KEYI.Windows/app.manifest` 的 assemblyIdentity 必须与之一致。`Scripts/test.sh` 在跑任何
  检查前先比对，不一致即失败。
- **凭据只在系统凭据库。** macOS 走 Keychain（service `com.keyi.credentials`），Windows 走
  Credential Manager。设置文件只存端点、模型名、偏好，绝不存密钥。
- **诊断信息不含文本。** 错误只带稳定类别码（如 `content_changed`、`terminal_write_failed`），
  日志同样不写捕获或翻译的内容。
- **签名即发布边界。** macOS 正式分发要求 Developer ID 签名；Windows 正式分发要求 Authenticode
  签名与 10/11 原生安装／升级验收。当前二进制是实验性的，这两条尚未满足。

## 已知边界（已确认）

- 网页输入框只能用通用辅助功能加粘贴来写，无法证明任意网站内部编辑器状态；不做浏览器扩展是刻意决策。
- 英文风格的自然度没有自动测试：自动检查只验证提示词组装与规则覆盖，自然度靠匿名人工评审。
- Windows 上微信等 Qt 自绘控件不暴露 UIA 文本模式，只能在用户已有选区时临时复制读取并恢复剪贴板；
  这条降级路径尚未完成实机验收。
- 不提供自动更新；实验版二进制未签名。
