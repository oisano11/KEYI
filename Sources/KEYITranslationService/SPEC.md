---
id: keyi-translation-service
type: module-design
title: 伴随翻译服务 — socket 服务循环与宿主装配
status: draft
parent: keyi-ime
tags:
  - module
  - macos
  - service
---

# 伴随翻译服务

## 职责

在 KEYI 可译（`com.keyi.input-translator`）进程内监听本机 socket，把输入法发来的翻译请求交给
宿主提供的提供方实现。代码在 `Sources/KEYITranslationService/`（服务循环、契约、装配）与
`Sources/KEYIUI/KEYITranslationServiceHost.swift`（宿主侧装配）。

协议本身归 [keyi-translation-wire](keyi-translation-wire)；本文件只管服务这一侧怎么跑。

## 方向

`KEYITranslationService` **不依赖** KEYIUI，也不 import `Translation` 框架。依赖只有
`KEYICore` 与共享的线协议包。宿主（KEYIUI）实现 `TranslationServiceResolving` 并注入。

这条边是真实约束：系统翻译需要 `Translation` 框架与主线程的 `translationTask` 才能触发语言包
安装，只有应用进程能提供；把它放进服务 target 会让服务无法在无 GUI 环境里构建与测试。

## 服务跑在子进程里

KEYI 可译用 `Bundle.main.executableURL` 加 `TranslationServiceRunner.childProcessArguments()`
（即 `--keyi-translation-service`）把自己再启动一次。这个实例不创建菜单栏 UI，只跑 socket 循环。

单实例靠 socket 探活：启动时若 `TranslationServiceSocketProbe.isServiceRunning` 为真，就记日志、
写一行 stderr、以 `EXIT_SUCCESS` 退出。不做 pid 文件 —— 探活判据与实际占用必须是同一个东西。

`Sources/KEYITranslationServiceCLI` 是同一个 runner 的前台入口，用相同的提供方路由，供排障时在
终端里直接跑；默认 socket 路径与客户端一致。

## 每个请求都重新读配置

宿主注入的 `configuration` 闭包每次请求都 `reloadPreferences()`，不用启动时的快照。用户刚在设置里
换了提供方，下一句就该按新的翻，不需要重启伴随应用。

## 并发与拒绝

`maximumConcurrentRequests` 默认 4（常量夹到至少 1 条）。超限的连接直接回 `error(type=error,
code=busy)`，不排队 —— 排队会让用户以为输入法卡了，而排队中的文本很快就不再有意义。

socket 目录随服务启动创建，socket 文件 `chmod` 到仅属主可读写；`chmod` 失败只记 warning 并继续
运行 —— 拒绝服务比权限收紧失败更糟。accept 时逐连接禁 `SIGPIPE`，不改进程全局信号行为。

## 翻译风格与引擎

用户只选 6 种风格之一（`KEYITranslationStyle`，在共享包里，存于 KEYI 可译偏好域
`translation.stylePreset`，输入法菜单也能改）。每次请求按 `TranslationStyleRouting.route` 现算引擎：
自然、正式商务、贴近原文用本地模型，没下载时暂用苹果翻译；地道美式口语、黑人英语口语、英式口语用已配置的
云端服务（上次选用的优先，否则按清单第一个），没配好就按「自然」走本地。旧版的「翻译方式/场景/英语风格」
只在第一次升级时用来推出最接近的风格。

每次算路由时，KEYI 可译把每个风格现在用的引擎名写进同一偏好域的 `translation.styleEngineLabels`
（风格 rawValue → 名字：Hy-MT2、苹果翻译、DeepSeek 等服务名，没配 API 写「需 API Key」）。
输入法菜单、菜单栏和设置首页都在风格名后显示这个名字，不写「云端」「联网」；没写过时输入法菜单只显示风格名。

## 凭据与提供方

服务端自己装配：`TranslationSettingsStore` 加 Apple 翻译会话；`apiProvider` 要求该提供方可用且需要
API 配置，否则为 nil；`localProvider` 在用户没选过 Hy-MT2 档位时为 nil，选了但没下载（或校验失效）
抛 `notConfigured`，否则构造连自带 llama-server 的提供方。服务由主应用常驻运行，子进程不启动它，只经
运行目录的 socket 和密钥连过去，最多等 10 秒模型加载。

未安装的 Apple 语言对必须抛错并映射成 `unavailableProvider`，不能返回原文 —— 返回原文会被当成
「翻译成功」直接写回用户文档。

## 进程生命周期

服务随 KEYI 可译退出而终止（`stop()` 直接 `terminate()`）。子进程的 stdout/stderr 都指向
null device：它不该往用户的终端或日志里写字。

## 已知边界（已确认）

- socket 权限是 0600，但路径本身可读。同一用户的其他进程可以尝试连接 —— 这道边界是「不跨用户」，
  不是「不跨同用户进程」。
- 服务依赖宿主提供的 Apple 翻译会话，因此不能在没有 KEYI 可译 UI 进程的环境里独立验证系统翻译。
- 未做跨设备或 TCP 监听，刻意如此。
