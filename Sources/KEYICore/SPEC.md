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
- **终端宿主路由**（`TerminalHostCapabilities`）：把终端和编辑器类宿主分成五种路由 —— 普通输入框、
  可写的终端草稿、可写的 VS Code 编辑器字段、只读屏幕内容的终端（拒绝）、未分类的混合目标（拒绝）。
  只有前三者允许读 AXValue；白名单是 Terminal、iTerm2、Ghostty、Warp、WezTerm、kitty、alacritty
  与 VS Code（后者只对明确可写的编辑器字段放行，xterm.js 与未知控件一律关闭）。**失败即拒绝**，
  不猜、不降级成模拟按键。
- **终端草稿文件**（`TerminalDraftFile`、`TerminalEditorDocument`）：读写一个**被显式指定**的编辑器
  文件，按 device／inode／属主／链接数／权限与 size／mtime／ctime 指纹做条件写回，`flock` 只是建议
  锁。它是编辑器交接，不是屏幕抓取：上下文留在文件里，永不作为可编辑或翻译的草稿暴露。
- **提供方目录**（`TranslationProvider`）：`TranslationProviderID`（appleSystem、deepSeek、qwen、
  volcengine、xAI、relay、localModel）、各提供方的默认端点与模型、火山方舟从 `/responses` 到
  `/chat/completions` 的历史配置迁移、场合（`TranslationScene`）与英文风格（`EnglishStyle`）、
  十三种目标语言、界面语言。
- **英文风格启用规则**（`usesEnglishStyle`）：目标语言是英语、且场合不是商务或贴近原文。这是唯一事实
  来源，菜单可用性与提示词都读它。
- **提示词组装**（`TranslationPromptBuilder`）：云端提供方用系统提示加用户提示；用户内容以 JSON
  载荷注入，源文一律当作内容而非指令。
- **本地模型清单与提示词**（`LocalTranslationModelCatalog`、`HyMTPromptBuilder`）：两档 Hy-MT2-1.8B
  GGUF（轻量 Q4_K_M、标准 Q8_0）的文件名、字节数、sha256、固定 revision 的下载地址（ModelScope
  在前、Hugging Face 在后），以及官方推荐的采样参数。清单只是数据，Windows 版照抄同一份。
  Hy-MT2 没有系统提示，所以本地请求只有一条 user 消息，源文直接嵌入官方中文模板，不用 JSON 载荷：
  轻量档只用默认翻译模板；标准档在有场景（非自动）、英语风格（按 `usesEnglishStyle`，非自然）或
  不同于源文的输入框全文时改用官方「【背景信息】」模板，全文只取最后 1000 个字符，三者都没有时
  退回默认模板。
- **HTTP 语义**（`OpenAICompatibleTranslationProvider`）：OpenAI 兼容的 chat completions 调用，
  对 200 但空内容、被 `finish_reason` 截断、非 2xx 分别给出不同错误，不把失败伪装成空译文。

## 边界

- 只 import Foundation（另有一处 Darwin，在 `TerminalDraftFile`，用 POSIX 文件调用）。**不得**引入 AppKit、SwiftUI、ApplicationServices、Translation、
  Security —— 一旦引入，`KEYICoreChecks` 就不再能在无界面环境下运行。
- 不认识「焦点控件」「辅助功能」「快捷键」「设置窗口」这些概念；它只接收结构化请求，返回文本或错误。
- 不读写偏好与凭据、不写日志、不缓存译文。唯一触碰文件的是调用方显式给出的编辑器草稿路径，且只
  在该路径上按指纹复核后条件写回。

## 相关

- 英文风格的具体规则见 [keyi-english-style](keyi-english-style)。
