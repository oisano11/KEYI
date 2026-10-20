---
id: keyi-core
type: module-design
title: KEYICore — 跨平台无关的翻译核心
status: active
parent: keyi-architecture
tags:
  - module
  - macos
references:
  - keyi-english-style
---

# KEYICore — 跨平台无关的翻译核心

## 职责

承载「不依赖任何界面或系统 API」的翻译语义：什么是一段可选中的文本、怎么把一个选区换掉、
提示词长什么样、有哪些提供方、模型返回什么算失败。

它存在的理由是可测性：这些规则决定了翻译**说什么**，而它们全都适合在没有窗口、没有辅助功能权限的
CI 机器上逐条断言。

## 拥有的东西

- **选区模型**（`FocusedTextSelection`）：零长度选区等同全文；UTF-16 越界即无效；
  `replacing(in:with:)` 用可变字符串做区间替换，保留前后文逐字不变。
- **终端命令行识别**（`TerminalCommandSelection`）：仅当光标为零长度时生效，按提示符
  （`% `、`$ `、`# `、`> `）剥出当前行命令；`isSafeReplacement` 拒绝空串与任何控制字符／换行，
  因为终端里一次回车就是一次执行。
- **提供方目录**（`TranslationProvider`）：`TranslationProviderID`（appleSystem、deepSeek、qwen、
  volcengine、xAI、relay、localModel）、各提供方的默认端点与模型、火山方舟从 `/responses` 到
  `/chat/completions` 的历史配置迁移、场合（`TranslationScene`）与英文风格（`EnglishStyle`）、
  十三种目标语言、界面语言。
- **英文风格启用规则**（`usesEnglishStyle`）：目标语言是英语、且场合不是商务或贴近原文。这是唯一事实
  来源，菜单可用性与提示词都读它。
- **提示词组装**（`TranslationPromptBuilder`）：系统提示与用户提示，云端与本地两套；用户内容以 JSON
  载荷注入，源文一律当作内容而非指令。
- **HTTP 语义**（`OpenAICompatibleTranslationProvider`）：OpenAI 兼容的 chat completions 调用，
  对 200 但空内容、被 `finish_reason` 截断、非 2xx 分别给出不同错误，不把失败伪装成空译文。

## 边界

- 只 import Foundation。**不得**引入 AppKit、SwiftUI、ApplicationServices、Translation、Security ——
  一旦引入，`KEYICoreChecks` 就不再能在无界面环境下运行。
- 不认识「焦点控件」「辅助功能」「快捷键」「设置窗口」这些概念；它只接收结构化请求，返回文本或错误。
- 不读凭据、不发日志、不持久化。密钥与状态属于应用层。

## 相关

- 英文风格的具体规则见 [keyi-english-style](keyi-english-style)。
