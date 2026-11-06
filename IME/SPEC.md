---
id: keyi-ime
type: architecture-design
title: KEYI 拼音输入法层 — IMK 外壳、Rime 引擎与自动翻译
status: draft
parent: keyi
tags:
  - architecture
  - macos
  - ime
---

# KEYI 拼音输入法层

## 这一层是什么

[keyi](keyi) 的范围声明说，本套 spec 原本只覆盖 `main` 上那层「按快捷键翻译」。这份文件补上
另一层：KEYI 自己的拼音输入法（KEYIIME）。它只在集成分支 `codex/keyi-integration-03` 的 `IME/`、
`Packages/` 里，尚未进入 `main`。

两层的区别不在翻译质量，而在**谁来决定翻译什么、什么时候翻**：桌面层由用户按快捷键发起，输入法层
由用户确认中文这个动作发起。产品的唯一主目标由仓库根的 `PRODUCT_SCOPE.md` 定义，就是后者 ——
选 KEYI 拼音输入源、正常输入并确认汉字，原位置直接得到译文，没有额外的翻译快捷键、选区或菜单。

这层不重写拼音引擎。候选、词库、断词全部来自 librime 与固定版本的雾凇拼音（rime-ice），本层只做
三件事：把 InputMethodKit 的事件交给 Rime、把 Rime 的结果画成候选窗、以及把「本会话刚确认的中文」
整段暂存在输入法里、回车时再上屏译文。

## 形状

输入法进程（`KEYIIME`）是一层 IMK 外壳，内部按职责分成三段，全部在同一个进程里：

- **引擎与桥接**（`KeyiIMECore` + `KeyiIMEBridge` + `KeyiIMEInputController`）：各只有一对源文件，
  是 librime 的 C++ 包装、Objective-C 桥，以及 InputMethodKit 要求的那层 legacy 控制器 shim。
  它们是薄适配，不是独立边界 —— 一个 `RimeEngine` 实例只拥有一个 Rime 会话，两段组合因此不共享
  状态；派生关系与许可见 `IME/SOURCES.md`。
- **会话策略**（`KeyiIMEKit`）：唯一持有「这次组合属于哪个输入框」的地方，决定哪些键归自己、
  哪些键放行，并在提交路径上把文字交给翻译。见 [keyi-ime-session](keyi-ime-session)。
- **自动翻译**（`KeyiIMETranslation`）：停手判据、请求生命周期、写回校验、失败分类。见
  [keyi-ime-autotranslate](keyi-ime-autotranslate)。

翻译不在这个进程里发生。[keyi-translation-wire](keyi-translation-wire) 定义的本机 socket 协议
把请求送出去，[keyi-translation-service](keyi-translation-service) 在 KEYI 可译伴随应用的子进程
里接收并调用提供方。

## 运行时拓扑

```
用户按键 ──▶ InputSession ──▶ librime ──▶ 候选窗
                 │
                 └─ 确认中文（Rime commit）──▶ takeCommit：并进暂存段落，不上屏
                                                  │
                 标记文字 = 暂存中文 + 拼音（应用画下划线）
                                                  │
                    停手 ──▶ 预览请求（只进浮层）      回车 ──▶ 转换请求
                                                  │
                              AF_UNIX/NDJSON ──▶ 翻译服务子进程
                                                  │
                              提供方（云 / 系统 / 本机 LM Studio）
                                                  │
上屏：insertText(英文, replacementRange: 当前标记范围)，剩下的继续 setMarkedText ◀──┘
```

中文在按回车之前一直是标记文字，还没交给应用（。？！ 只是普通文字，不打断输入）；回车后一次性把
英文作为普通上屏写进去。这是
终端也能工作的唯一做法 —— 终端会忽略对已上屏文字的替换、也读不回文字。英文上屏后就是普通文字，
退格交给应用（用户 2026-10-31 实测后选定，所有应用一样）。

## 不变量

**输入法进程不联网、不持凭据。** `IME/` 内没有 `URLSession`、`NWConnection`、`CFStream`；线协议里
没有任何 API Key，服务端永远读自己进程内的配置与 Keychain。这条边界让「输入法」这个高权限、常驻、
无窗口的进程不必承担网络与密钥的风险。

**翻译只由本会话新确认的中文触发。** 入口只有 Rime commit 之后那一次 `takeCommit`；
原始拼音（暂存期间用回车上屏的字母除外，它并进段落一起翻）、未确认候选、其他输入法写入的内容、
宿主已有全文，都不进入这条路径。

**停手界限跟随用户，不写死秒数。** 界限由用户自己的打字节奏推出，节奏样本跨输入框共享 —— 节奏
属于人，不属于某个输入框。停手现在只更新浮层预览，不改输入框；参数是实现细节，但「无需额外翻译
操作」是产品边界。

**写进输入框前必须证明还归我们。** 按键之外上屏英文前，应用报告的标记长度要等于「暂存 + 拼音」，
不符就放弃、什么都不写。输入法从不改已上屏的文字。安全输入打开时不发请求、不应用结果。

**失败保留原文。** 连不上、超时、空结果都只提示，不改动文档；连不上伴随应用时自动重试一次，
不无限重试。密码与安全输入不进翻译。

**永不替用户发送。** 本层不产生回车、不提交表单、不发送消息。有暂存段落时，第一下回车只把它换成
英文、不交给宿主；英文还没出来时再按一下就原样上屏中文、仍不发送；什么都不暂存时回车才交给宿主。

## 注册与身份

Bundle ID `com.keyi.inputmethod.keyi`、模式 `com.keyi.inputmethod.keyi.pinyin`、连接名
`com.keyi.inputmethod.keyi_Connection`。标识符里的 `.inputmethod.` 段**不能是末段** —— 这是 macOS
注册第三方输入法的硬性要求，旧写法 `com.keyi.input-method` 因此从不出现于 TIS 枚举。安装脚本与
`--register-installed` 只注册、不启用也不切换输入源，加入系统设置仍由用户完成。

Rime 用户数据仍留在 `~/Library/Application Support/com.keyi.input-method/Rime`，偏好域同为
`com.keyi.input-method`：这两处刻意不随 Bundle ID 迁移，否则用户词库会在一次升级里凭空消失。

## 已知边界（已确认）

- **这层没有进 `main`。** 集成分支领先 `main` 上百个提交，`IME/`、`Packages/`、
  `Sources/KEYITranslationService` 都只在集成分支。`main` 上装的 KEYI 可译没有本层。
- **没有 Windows 对应实现。** Windows 侧只到桌面快捷键翻译（[keyi-windows-app](keyi-windows-app)）。
- **真机验收范围有限。** 已验证的是 `IME/Scripts/run-tests.sh` 的四层自动化（引擎 smoke、自动翻译
  检查、打包校验、会话诊断），它们都不安装、不选择输入源；真实宿主里的行为（各种 App 的输入框、
  网页编辑器、终端）只经过部分手测。
- **雾凇词库不能统一按 Apache-2.0 授权。** 词库来源多，随包带 `CREDITS.rime-ice.md` 与
  `LICENSE.rime-ice-GPL-3.0`；只引入全拼词库，不引入 Lua、OpenCC、双拼、拆字或语法模型。
