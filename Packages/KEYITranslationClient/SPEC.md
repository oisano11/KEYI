---
id: keyi-translation-wire
type: submodule-design
title: 翻译线协议 v1 — 本机 socket 上唯一被冻结的契约
status: draft
parent: keyi-ime
tags:
  - contract
  - ipc
  - macos
---

# 翻译线协议 v1

## 职责

输入法进程与 KEYI 可译伴随应用之间的唯一契约。代码只有一份，在共享包
`Packages/KEYITranslationClient` —— 两端都依赖它，不再逐字节复制。

改动这个协议等于同时改动两个进程、两个包。先问「能不能不改线协议就做到」。

## 传输

AF_UNIX / SOCK_STREAM，UTF-8 JSON 一行一对象以 `\n` 结束（NDJSON）。

socket 路径 = `~/Library/Application Support/com.keyi.input-translator/translation-service.sock`；
路径长度不满足 `sun_path < 104` 字节时退到 `/tmp/keyi-<uid>-translation.sock`。两侧必须用同一个
`TranslationServiceSocketPath.defaultPath()` 计算，不能各自拼路径。

## 一请求一连接

客户端连上后发一条请求；服务端返回零条或多条中间事件，最后一条必为终止事件（`result` /
`error` / `cancelled`），然后关闭连接。

请求类型 `translate` / `cancel` / `status` / `ping`；事件类型 `result` / `error` / `cancelled` /
`serviceStatus` / `pong`。`id` 是 UUID 字符串，服务端只处理与当前连接请求 id 一致的结果。

## 取消与迟到

服务端在连接断开或 id 过期时，迟到的提供方结果**一律丢弃** —— 不回写、不复用。取消可以显式发
`cancel`（同一 id），也可以直接断开；两种都视为取消，都不产生任何翻译写回。

`timeoutSeconds` 默认 30、服务端上限 120；服务端超时返回 `error(timeout)`。客户端在服务端超时
基础上加 2 秒宽限，客户端超时后立即关闭连接，服务端据此取消在途翻译。自动翻译自己用 10 秒，
不是这个默认值。

## 协议里没有密钥

请求与事件都不携带 API Key。服务端永远读自己进程内已配置的提供方与系统凭据库。输入法进程因此
不必持有凭据 —— 这条边界比「少存一份密钥」更重要：输入法是常驻、高权限、无窗口的进程。

## 错误码

九种：`serviceUnavailable`、`badRequest`、`notConfigured`、`unavailableProvider`、`busy`、
`timeout`、`cancelled`、`providerError`、`internalError`。客户端把它们折成五种错误
（`TranslationServiceClientError`），自动翻译再折成五类失败类别
（[keyi-ime-autotranslate](keyi-ime-autotranslate)）。

`notConfigured` 与 `unavailableProvider` 在界面上都表现为「还没配好」，语义不同：
前者是用户没配置，后者是配置了但当前不可用（语言包没装、本机模型没起来）。

## 版本与尺寸

`version = 1`；`maximumMessageBytes = 64 * 1024`。消息超限按 `badRequest` 拒绝，不截断 ——
截断的文本会被当成完整句子翻出去。

## 语音识别（2026-11-07）

一段录音用一个连接，是「一请求一连接」里唯一由客户端连续发多条的：`transcribe`（带 `sampleRate`）→
若干 `audio`（`audio` 字段是一帧 16 位小端单声道 PCM 的 base64，输入法每帧 100 毫秒，约 4.3 KB，远低于
单条上限）→ `finishAudio`。服务端先回 `transcriptStarted`（`message` 是引擎显示名，如「阿里云 Fun-ASR」「豆包语音识别」）
或 `error`（没选云端、没配好时 `notConfigured`），之后回若干 `transcript`（`text` 是到此刻的整段，后来的
覆盖前面的），终止事件是 `result`（`text` 为定稿）或 `error`。客户端断开即取消，服务端停掉云端识别。

客户端在共享包 `TranslationServiceSpeechStream`：后台线程连上并发出 `transcribe`，连上前送的帧排着；
写在一条串行队列上，关闭也在这条队列上，不会写到复用的 fd。协议里仍然没有密钥：云端用的 Key 只在
KEYI 可译里。旧版服务看不懂 `transcribe`，回 `badRequest`，输入法当作没配好、用本机识别。

