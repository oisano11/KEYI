---
id: keyi-local-model
type: submodule-design
title: 本地模型 — 只信任本机已签名的 LM Studio
status: draft
parent: keyi-ui
tags:
  - module
  - macos
  - security
---

# 本地模型 — 只信任本机已签名的 LM Studio

## 职责

让用户可以把待翻译的文本交给本机运行的 LM Studio 模型，同时不把这段文本泄露给本机上的任何其他进程。

前提：**模型标识不是身份认证。** 一个监听 `127.0.0.1:1234` 的进程可能是 LM Studio，也可能是任何
别的程序。所以「连上去试一下」不构成信任 —— 必须证明对端是那个已签名的应用。

代码在 `Sources/KEYIUI/LocalModelTrust.swift`、`LocalModelRuntime.swift`、
`LocalModelTranslationProvider.swift`。

## 信任链

1. **端点形状**：只接受 `http`、主机限于 `127.0.0.1`／`localhost`／`[::1]`／`::1`、不得携带用户名或
   密码；`localhost` 一律改写成 `127.0.0.1`，避免解析到别的主机。
2. **监听者身份**：用 `lsof -nP -a -iTCP:<port> -sTCP:LISTEN -Fp` 找出该端口上的**所有**监听进程，
   每一个都必须通过下面的校验 —— 有一个可疑就整体拒绝。
3. **进程签名**：`SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity` 确认进程本身的签名有效。
4. **应用身份**：从主可执行文件向外找到所属的 `LM Studio.app`，要求它位于 `/Applications/` 或
   `~/Applications/`，且 `CFBundleName` 为 `LM Studio`。
5. **静态校验与团队一致**：`anchor apple generic` 要求 + `kSecCSStrictValidate`；应用与进程的
   Team ID 必须相等（不硬编码任何 Team ID）。
6. **传输**：会话是 ephemeral 的，代理字典清空，重定向一律取消 —— 文本不会被转发到别处。

## 运行时

`LocalModelRuntime` 在模型不可用时尝试启动本机 LM Studio 服务并加载默认模型；找不到可执行文件、
模型未安装、服务不可用分别给出不同错误，不做无限重试。默认配置（端点、模型名、加载键、输出预算、
空闲卸载时限）来自 `KEYICore.LocalModelCatalog`。

`LocalModelTranslationProvider` 在输出被截断时以更大预算重试一次；仍然拿不到译文就报错，而不是把
半句话交给写回层。

## 边界

- 只支持 LM Studio：其他本地推理服务即使兼容 OpenAI 接口也不被信任，因为它们无法通过上述签名链。
- 文本只发往本机回环地址；**不**把完整输入框上下文发给云端 —— 完整上下文只用于本地模型。
- 端点校验失败时明确报 `invalidLocalEndpoint`，不回退到默认地址。
