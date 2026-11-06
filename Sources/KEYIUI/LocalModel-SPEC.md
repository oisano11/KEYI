---
id: keyi-local-model
type: submodule-design
title: 本地模型 — KEYI 自带的 Hy-MT2
status: active
parent: keyi-ui
tags:
  - module
  - macos
  - security
---

# 本地模型 — KEYI 自带的 Hy-MT2

## 职责

让用户可以把待翻译的文本交给本机运行的翻译模型，同时不把这段文本泄露给本机上的任何其他进程。
按 PRODUCT_SCOPE「2026-11-01 KEYI 自带本地翻译模型授权」，模型是腾讯混元 Hy-MT2-1.8B，跑在 KEYI
自带的 llama-server 里；不再连 LM Studio 或任何外部本地服务。

代码：清单与提示词 `KEYICore/LocalTranslationModel.swift`；下载 `LocalModelDownloader.swift`；
服务 `LocalModelServer.swift`、`LocalModelHTTPClient.swift`；翻译 `LocalModelTranslationProvider.swift`。

## 模型与下载

- 两档：轻量 Q4_K_M（只直译）、标准 Q8_0（把场景、英语风格和输入框上下文写进提示词）。清单固定
  revision、字节数和 sha256，ModelScope 优先、Hugging Face 备用。
- 只在用户点「下载」时下载，支持断点续传；字节数和 sha256 都对上才改名成正式文件，并记下文件身份。
  界面用 `isInstalled` 判断，不读文件内容。删除会连同半截文件和校验记录一起删。
- 下载在 `AppModel` 里进行，关掉设置窗口不会中断；进度和失败原因按档位显示在设置里。

## 选择与运行

- 用户在设置里点某一档的「用于翻译」：记下档位（`translation.local.tier`），提供方切到本地模型。
  没选档位或该档没下载时，菜单里选「本地模型」只打开设置页，不切换。
- `AppModel.syncLocalModelServer`：提供方是本地模型且该档已下载时让服务加载它，否则停掉服务释放内存。
  KEYI 启动、切换提供方、下载完成、删除模型、每次桌面翻译前都调用；KEYI 退出时停服务。
- 服务连续失败放弃后，下一次翻译会再拉起一次；输入法经翻译服务子进程翻译时不拉起，直接报失败原因。
- 删除正在使用的那一档会先切回苹果系统翻译。

## 自带服务（llama-server）

按 PRODUCT_SCOPE「2026-11-01 KEYI 自带本地翻译模型授权」，KEYI 自带官方 llama.cpp（固定 b12032）的
`llama-server` 运行 Hy-MT2 模型。代码在 `LocalModelServer.swift`、`LocalModelHTTPClient.swift`，
打包在 `Scripts/build-app.sh`。

- **只走 UNIX socket**：服务监听运行目录里的 `llama.sock`，不开 TCP 端口；启动参数固定
  `--offline --no-slots --no-webui --cache-ram 0 -c 8192 -np 1`。
- **运行目录**：`Application Support/com.keyi.input-translator/run`（路径超出 `sun_path` 时退到
  `/tmp/keyi-<uid>-llama`）。必须是当前用户拥有的真实目录（不是符号链接），权限 0700，不对就改回或拒绝。
- **密钥**：每次启动用 `SecRandomCopyBytes` 生成 32 字节随机 key，写成 0600 的 `llama.key`，
  通过 `--api-key-file` 交给服务；请求带 `Authorization: Bearer`。日志 `llama.log` 也是 0600。
- **谁来连**：主应用持有进程；主应用和翻译服务子进程都用 `LocalModelConnection.readyEndpoint`
  读 key 文件、查 `/health`，模型加载中最多等给定时长。
- **崩溃与放弃**：进程意外退出就重启；连续 3 次没能就绪便停下，把原因写进 `llama.failed`，
  子进程读到后立即报错，不再等超时。主动停止会清掉 key、pid、socket 和失败记录。
- **遗留进程**：`llama.pid` 记下进程号。启动和停止前先读它，只有 `proc_pidpath` 指向自带 helper
  （`…/Contents/Helpers/llama/llama-server`）时才发 SIGTERM，之后才删 pid 文件。
- **打包与签名**：构建脚本下载固定版本并校验 sha256，只拷 `llama-server` 和它按 `@rpath` 引用的
  10 个 dylib 到 `Contents/Helpers/llama/`，许可证放 `Contents/Resources/Licenses/`。每个文件用
  hardened runtime 签名；本地签名没有 Team ID，development/adhoc 模式给 llama-server 加
  `com.apple.security.cs.disable-library-validation`，distribution 用同一 Developer ID，不加。

## 翻译请求

- Hy-MT2 不用系统提示：只发一条 user 消息（`HyMTPromptBuilder`，取自官方 README 的中文模板）。
  采样参数按 README 对 1.8B 的推荐（top_p 0.6、top_k 20、repeat_penalty 1.05），`max_tokens` 4096，
  不流式；温度从推荐的 0.7 降到 0.2——0.7 时同一句每次译法不同，还会抽到跑偏的译文。
- 标准档只写场景和输入框全文，不写英语风格：1.8B 模型基本不按风格描述改写，反而更容易跑偏。
- 术语表 `HyMTGlossary`：原文里出现的常用口语、网络用语和商务词，按官方「术语干预」模板
  （「参考下面的翻译：X 翻译成 Y」）放在最前面，只用于译成英语。只收意思固定、放进任何句子都通顺的
  完整说法。「老王」「小李」这类「老/小 + 常见姓」的称呼另按规则保留拼音（Lao Wang、Xiao Li）。评测句在 `Tests/KEYILocalModelEval/`（`run.py` 直连自带服务，对比改动前后）。
- 一次翻译先等服务就绪，最多 10 秒（模型启动时已在后台加载，通常不用等）；请求本身最多 60 秒。
- `finish_reason` 为 `length` 时报「输出过长」，不把半句话交给写回层；空译文、非 2xx 分别报错。

## 旧版迁移

`TranslationSettingsStore` 初始化时删掉旧 LM Studio 的地址和模型名。正在用本地模型、但还没选过
Hy-MT2 档位的用户切回苹果系统翻译，并留一次提示：菜单顶部出现一行说明，点开（跳到本地模型设置）或
改选任何提供方后不再出现。

## 边界

- 文本只经当前用户 0700 目录里的 UNIX socket 发给自带服务，不开 TCP 端口，不发到网上。
- 不自动下载、不自动切换提供方；Windows 版本轮不做，只让清单与提示词可复用。
