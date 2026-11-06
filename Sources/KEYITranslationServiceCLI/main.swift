//
//  main.swift
//  KEYITranslationServiceCLI
//
//  阶段 02 的排错入口：在终端里前台运行翻译服务，用与 KEYI 可译相同的
//  提供方路由（已保存配置 + Keychain 凭据 + 系统翻译会话）。
//
//  用法：
//      swift run KEYITranslationServiceCLI [--socket /tmp/keyi-dev.sock]
//
//  进程只使用 macOS 框架（Foundation/AppKit 由 KEYIUI 间接引入），
//  不启动菜单栏 UI；默认 socket 路径与客户端 `TranslationServiceSocketPath` 一致。
//

import AppKit
import Foundation
import KEYIUI
import KEYITranslationClient
import KEYITranslationService

let arguments = CommandLine.arguments
let socketPath = TranslationServiceRunner.socketPath(arguments: arguments)

FileHandle.standardError.write(
    Data("KEYI 翻译服务（CLI）启动中，socket=\(socketPath)\n".utf8)
)

// 有些系统框架（Translation）要求进程有 AppKit 的运行时环境；
// 这里不创建窗口、不进入激活策略，仅初始化运行时。
_ = NSApplication.shared

let resolver = KEYITranslationResolverFactory.make()
TranslationServiceRunner.run(resolver: resolver, socketPath: socketPath) { path in
    FileHandle.standardError.write(Data("KEYI 翻译服务已就绪：\(path)\n".utf8))
}
