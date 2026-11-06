---
id: keyi-writeback
type: submodule-design
title: 写回 — 辅助功能快照与安全替换
status: active
parent: keyi-ui
tags:
  - module
  - macos
  - risk
---

# 写回 — 辅助功能快照与安全替换

## 职责

把译文放回**原来那个控件的原来那段文字**，并在任何证据不足时拒绝动手。这是整个产品风险最高的地方：
一次错误替换会毁掉用户正在写的东西。

代码在 `Sources/KEYIUI/AccessibilityTextClient.swift`（入口 `capture` / `replace` 与校验），按职责分到同目录的
`AccessibilityTextClient+Capture`（取文）、`+Paste`（粘贴式写回）、`+Terminal`（终端路由与命令行写回）、
`+ZshDraft`（zsh 草稿）、`+AXAttributes`（AX 属性小工具），剪贴板快照在 `ScopedPasteboard.swift`。

## 一次写回的完整契约

1. **捕获（capture）**：先判断宿主路由（`TerminalHostCapabilities`）。只读屏幕内容的终端与未分类的
   混合目标直接拒绝，转交终端草稿编辑器；其余先走辅助功能读焦点控件的值与选区；当控件读不出
   （`noFocusedText`、`unreadableText`、`readOnlyText`）时，退到键盘路径：读当前选区，必要时让网页
   文本框全选后读全文。两条路径都产出一个 `Snapshot`：目标身份、原始全文、原始选区、写入模式、
   终端标记，以及可选的 `TerminalDraftObservation` 与 zsh 草稿票。
2. **翻译**：发生在快照之外，期间用户随时可能改动文字或换窗口。
3. **写回（replace）**：按写入模式分派，每一种都先复核再落笔。

## 六种写入模式

| 模式 | 用在 | 落笔方式 |
| --- | --- | --- |
| `value` | 可写 `AXValue` 的普通输入框 | 直接写整个新值 |
| `selectedText` | 支持替换选区的控件 | 写 `AXSelectedText` |
| `browserPaste` | 网页输入框（有 `AXWebArea` 祖先） | 设选区 → 原生粘贴 → 读回比对 |
| `keyboardPaste` | 辅助功能读不到、只能靠键盘取文的控件 | 粘贴，等待选区更新 |
| `terminalPaste` | 终端里的命令行 | 退格删原文 → 粘贴译文，全程可中断 |
| `zshDraft` | zsh 的整段未提交缓冲区 | 提交给 shell 侧条件写回，回执确认才结束 |

## 终端的三条路

终端不是一个模式，而是三条互斥的路，由宿主路由在捕获时就选定：

- **可写的终端草稿**（Terminal、iTerm2、Ghostty、Warp、WezTerm、kitty、alacritty；以及 VS Code 里
  明确可写的编辑器字段）按普通输入框写回，但**写回前先订阅该元素的变更通知**（
  `TerminalDraftObservation`）。通知先于读值建立，订阅失败即放弃；通知回调从不读文本，它只是一个
  单向失效闩 —— 回到原值也不能让旧翻译复活。
- **整段 zsh 缓冲区**走 `zshDraft`：先捕获 `ZshDraftTicket`（缓冲区、光标、会话身份、前台 PID、
  焦点观察），翻译后把「同一份缓冲区、同一个票」提交给 shell 侧做条件写回，回执的 `ticketID` 与
  `committed` 都对上才算成功。它不碰剪贴板，也不发按键。
- **读不出也写不了的终端**（只读屏幕的终端、未分类的混合目标、模态状态）一律拒绝，抛
  `terminal_editor_required`，交给终端草稿编辑器（`KEYITerminal`）让用户审阅后手动粘贴。

## 不变量

- **绝不降级成直接写 `AXValue`。** 网页编辑器可能只更新显示文字而不更新内部状态，写 `AXValue`
  会「看起来成功」。网页路径只有粘贴一条路。
- **目标身份必须连续。** 快照记录了窗口、父节点、identifier、role；写回前重新取焦点控件并逐项比对。
  只有 `browserPaste` 允许控件被重建（网页重渲染会换元素），但仍要求值相同、选区相同。
- **内容必须未变。** 原始全文与原始选区都要与快照一致，否则 `contentChanged`。
- **每一步都可被打断。** `TranslationWriteBackGate.requireActive` 在落笔前检查本次翻译是否仍是当前
  那次；用户再次按快捷键或改变焦点，后续步骤直接抛 `CancellationError`。
- **剪贴板必须归还。** 所有粘贴路径都用 `ScopedPasteboard` 记录自己的写入；结束时只在剪贴板仍是
  自己写的内容时恢复原状 —— 用户中途复制了别的东西，就不覆盖。
- **终端永不执行。** 译文先经 `isSafeReplacement` 检查（无换行、无控制字符）；写入用退格加粘贴，
  不发送回车。焦点若已离开终端，改为 `terminalRecoveryRequired`，把原始命令交给「终端恢复」，
  由用户手动取回 —— 绝不在失焦后盲目粘贴。`zshDraft` 与草稿编辑器都不发回车。
- **失败有稳定类别。** 所有错误映射到不含文本的诊断码（`permission_required`、`content_changed`、
  `browser_input_failed`、`terminal_editor_required`、`terminal_write_failed`、
  `terminal_recovery_required`、`selection_update_timed_out`、`ax_write_failed` 等），日志同样不写内容。
  可写终端草稿上的失败一律归入 `terminal_write_failed`，不把 AX 错误码直接泄给用户。

## 已知边界（已确认）

- 网页写回对任意站点不可保证：`browserPaste` 在 800ms 内看到一次完整匹配就返回，这不能证明稍后不会
  被网页自身回滚，也不能证明网页内部提交状态正确。
- `keyboardPaste` 的旧路径等待较短、没有完整读回验证；它的「成功」不等于所有网页路径都成功。
- 通用辅助功能无法证明任意网站的内部状态；更高保证需要针对站点的浏览器扩展，本项目明确不做。
- `zshDraft` 只在 zsh 且用户主动 source 过绑定时可用。bash 与 fish 的绑定走另一条路：把当前缓冲区
  写进临时文件交给 `KEYITerminal edit`，回写前再比一次「用户没动过输入」，不是 `zshDraft` 机制。
  不可写的终端永远回落到草稿编辑器，不做按键模拟。
