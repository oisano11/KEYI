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

本文件描述 [keyi](keyi) 范围声明所述的那一层：`main` 上的桌面快捷键翻译。输入法及其自动触发
链路在集成分支，不在本图的层数之内 —— 它自成一层，见 [keyi-ime](keyi-ime)。

## 形状

两套原生实现共享同一份产品契约（见 [keyi](keyi)），不共享源代码：macOS 用 Swift，Windows 用 C#。
各自一条三层依赖链，方向唯一：

```text
macOS:    KEYI (可执行入口) ──▶ KEYIUI ──▶ KEYICore
          KEYI 的子进程 翻译服务 ──▶ KEYICore（由 KEYIUI 装配并托管）
          KEYITerminal (草稿桥) ──▶ KEYIUI（复用它的草稿编辑器）
Windows:  KEYI.Windows (托盘应用) ──▶ KEYI.Core
```

- **核心层不碰系统 UI。** `KEYICore` 只 import Foundation（另有两处 Darwin，为 AF_UNIX 与文件锁）；
  `KEYI.Core` 只依赖 BCL。两者承载纯逻辑：选区模型、提示词、提供方目录、HTTP 语义、设置文件格式。
  终端相关的身份、路由与文件读写也在这里，因为它们是纯判定而非平台交互。
- **应用层承担一切平台交互**：辅助功能读写、全局快捷键、菜单栏／托盘、设置窗口、凭据库、签名校验、
  单实例、本机 socket 服务的宿主装配。平台的差异止步于此，不向上泄漏。
- **入口是薄壳。** macOS 的 `KEYI` target 只有 `KEYILauncher.run()`，负责单实例锁与启动；它先判
  `--keyi-translation-service`，是则只跑翻译服务循环，不抢锁也不建菜单栏。
- **终端草稿桥是第二个可执行**（`KEYITerminal`），复用 KEYIUI 的草稿编辑器与 KEYICore 的判定，
  不重写一套。

## 依赖边

跨层依赖只有一条：应用层 → 核心层。核心层永不 import 应用层；两个平台之间没有编译期依赖。

这条边是真实约束而非风格偏好：核心层的单元检查（`KEYICoreChecks`、`KEYI.CoreChecks`）在无 GUI 的
CI 机器上运行，一旦核心层触碰 AppKit／UIA，这些检查就无法执行。

## 运行时拓扑

```text
全局快捷键 ──▶ AppModel（唯一状态机）──▶ 提供方 ──▶ 译文
                    │                              ▲
                    │                              │ 本机 socket 请求
                    ▼                              │（输入法自动翻译、终端草稿）
            AccessibilityTextClient       翻译服务子进程
      （捕获快照 / 按快照写回）        （提供方、语言、凭据都在这一侧）
                    │
                    ▼
              目标应用的原输入框
```

一次翻译是一个**快照事务**：捕获时记下目标身份的完整证据（窗口、父节点、identifier、role）、原始
全文、原始选区、写入模式；写回前逐项复核，任一不符即取消。写回不是「把文本发过去」，而是「证明还是
那个位置，然后替换」。

应用与本机上的其他进程只有一个接口：翻译服务子进程在
`~/Library/Application Support/com.keyi.input-translator/translation-service.sock` 上监听 AF_UNIX
socket（路径超 `sun_path` 的 104 字节时退到 `/tmp/keyi-<uid>-translation.sock`）。输入法的自动翻译与
`KEYITerminal` 的草稿编辑器都从这条入口进来，因此提供方、语言、凭据的判定只有一份，且 Keychain
只在服务进程里读。

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
- **系统翻译有两条路径，都不离本机。** 已安装的语言对走进程内的非 UI 会话（`prepareTranslation()`
  约 3–8 ms，同一会话可连续翻译多句，不会自动下载语言包）；只有需要 Apple 资源确认 UI 时才把请求
  交给主进程的 `translationTask`，那是一个 320×100、`.nonactivatingPanel` 的面板。
- **签名即发布边界。** macOS 正式分发要求 Developer ID 签名；Windows 正式分发要求 Authenticode
  签名与 10/11 原生安装／升级验收。当前二进制是实验性的，这两条尚未满足。

## 已知边界（已确认）

- 网页输入框只能用通用辅助功能加粘贴来写，无法证明任意网站内部编辑器状态；不做浏览器扩展是刻意决策。
- 英文风格的自然度没有自动测试：自动检查只验证提示词组装与规则覆盖，自然度靠匿名人工评审。
- Windows 上微信等 Qt 自绘控件不暴露 UIA 文本模式，只能在用户已有选区时临时复制读取并恢复剪贴板；
  这条降级路径尚未完成实机验收。
- 不提供自动更新；实验版二进制未签名。
