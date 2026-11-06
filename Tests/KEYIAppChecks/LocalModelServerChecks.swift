import Darwin
import Foundation
@testable import KEYIUI

/// 假的 llama-server：在 `--host` 指定的 UNIX socket 上应答 /health，其余路径要求正确的 Bearer key，
/// 并把收到的启动参数写进运行目录，供检查核对。
private let fakeServerScript = """
#!/usr/bin/python3
import os, socket, sys
args = sys.argv[1:]
host = args[args.index("--host") + 1]
key = open(args[args.index("--api-key-file") + 1]).read().strip()
with open(os.path.join(os.path.dirname(host), "args"), "w") as f:
    f.write("\\n".join(args))
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(host)
server.listen(4)
while True:
    client, _ = server.accept()
    data = b""
    while b"\\r\\n\\r\\n" not in data:
        chunk = client.recv(4096)
        if not chunk:
            break
        data += chunk
    lines = data.split(b"\\r\\n\\r\\n")[0].decode().split("\\r\\n")
    path = lines[0].split(" ")[1]
    auth = [line.split(":", 1)[1].strip() for line in lines if line.lower().startswith("authorization:")]
    if path == "/health":
        status, body = "200 OK", b'{"status":"ok"}'
    elif auth != ["Bearer " + key]:
        status, body = "401 Unauthorized", b'{"error":{"message":"Invalid API Key"}}'
    else:
        status, body = "200 OK", b'{"path":"' + path.encode() + b'"}'
    head = "HTTP/1.1 %s\\r\\nContent-Type: application/json\\r\\nContent-Length: %d\\r\\nConnection: close\\r\\n\\r\\n" % (status, len(body))
    client.sendall(head.encode() + body)
    client.close()
"""

@MainActor
func runLocalModelServerChecks() async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fatalError(message) }
    }
    func mode(_ url: URL) -> Int {
        var info = stat()
        return lstat(url.path, &info) == 0 ? Int(info.st_mode & 0o777) : -1
    }

    // HTTP 响应解析
    let complete = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello".utf8)
    let parsed = try LocalModelHTTPClient.parse(complete, atEnd: false)
    check(parsed?.status == 200 && parsed?.body == Data("hello".utf8), "应按 Content-Length 取出完整响应")
    check(try LocalModelHTTPClient.parse(complete.prefix(complete.count - 2), atEnd: false) == nil, "响应体没收全时应继续等")
    check((try? LocalModelHTTPClient.parse(complete.prefix(complete.count - 2), atEnd: true)) == nil, "连接已关闭但响应体不全应报错")
    check(try LocalModelHTTPClient.parse(Data("HTTP/1.1 401 Unauthorized\r\n".utf8), atEnd: false) == nil, "头部没收全时应继续等")
    let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n".utf8)
    check((try? LocalModelHTTPClient.parse(chunked, atEnd: false)) == nil, "不支持 chunked 响应")
    let untilClose = Data("HTTP/1.1 500 Internal Server Error\r\n\r\nboom".utf8)
    check(try LocalModelHTTPClient.parse(untilClose, atEnd: false) == nil, "没有 Content-Length 时应读到连接关闭")
    check(try LocalModelHTTPClient.parse(untilClose, atEnd: true)?.body == Data("boom".utf8), "连接关闭后应返回已收到的响应体")
    check((try? LocalModelHTTPClient.parse(Data("SSH-2.0\r\n\r\n".utf8), atEnd: false)) == nil, "非 HTTP 响应应报错")

    let root = URL(fileURLWithPath: "/tmp/kls-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // 运行目录
    let fresh = LocalModelRunDirectory(url: root.appendingPathComponent("fresh", isDirectory: true))
    try fresh.prepare()
    check(mode(fresh.url) == 0o700, "新建的运行目录权限应为 0700")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fresh.url.path)
    try fresh.prepare()
    check(mode(fresh.url) == 0o700, "运行目录权限被放宽后应改回 0700")
    let target = root.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    check(throwsUnsafe { try LocalModelRunDirectory(url: link).prepare() }, "运行目录是符号链接时应拒绝")
    let plainFile = root.appendingPathComponent("file")
    FileManager.default.createFile(atPath: plainFile.path, contents: Data())
    check(throwsUnsafe { try LocalModelRunDirectory(url: plainFile).prepare() }, "运行目录是普通文件时应拒绝")

    let model = root.appendingPathComponent("model.gguf")
    FileManager.default.createFile(atPath: model.path, contents: Data("gguf".utf8))

    // 正常启动、就绪、鉴权、停止
    let fakeHelper = root.appendingPathComponent("fake-llama-server")
    try writeExecutable(fakeServerScript, to: fakeHelper)
    let runDirectory = LocalModelRunDirectory(url: root.appendingPathComponent("run", isDirectory: true))
    let server = LocalModelServer(
        helperURL: fakeHelper,
        runDirectory: runDirectory,
        readyTimeout: .seconds(10),
        restartDelay: .milliseconds(10)
    )
    var states: [LocalModelServer.State] = []
    server.onStateChange = { states.append($0) }
    server.run(modelAt: model)
    check(server.state == .starting(model), "启动后应处于加载中")
    try await waitFor { server.state == .ready(model) }
    check(states == [.starting(model), .ready(model)], "状态应依次为加载中、就绪")
    check(mode(runDirectory.url) == 0o700, "运行目录权限应为 0700")
    check(mode(runDirectory.keyURL) == 0o600, "key 文件权限应为 0600")
    check(mode(runDirectory.logURL) == 0o600, "日志文件权限应为 0600")
    let arguments = try String(contentsOf: runDirectory.url.appendingPathComponent("args"), encoding: .utf8)
        .components(separatedBy: "\n")
    check(arguments.contains("--offline") && arguments.contains("--no-slots") && arguments.contains("--no-webui"), "应关闭联网、slots 接口和网页界面")
    check(flag("-c", in: arguments) == "8192" && flag("-np", in: arguments) == "1", "应给唯一的 slot 8192 上下文")
    check(flag("-m", in: arguments) == model.path, "应加载指定的模型文件")
    check(flag("--host", in: arguments) == runDirectory.socketURL.path, "应只监听运行目录里的 socket")

    let endpoint = try await LocalModelConnection.readyEndpoint(in: runDirectory, waitingUpTo: .seconds(1))
    let authorized = try await LocalModelHTTPClient.send("GET", "/v1/models", to: endpoint, timeout: .seconds(2))
    check(authorized.status == 200, "带正确 key 的请求应成功")
    let forged = LocalModelEndpoint(socketPath: endpoint.socketPath, apiKey: "wrong")
    let rejected = try await LocalModelHTTPClient.send("GET", "/v1/models", to: forged, timeout: .seconds(2))
    check(rejected.status == 401, "key 不对的请求应被拒绝")

    let pidText = try String(contentsOf: runDirectory.pidURL, encoding: .utf8)
    let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    server.run(modelAt: model)
    check(server.state == .ready(model), "同一模型已在运行时不应重启")
    server.stop()
    check(server.state == .stopped, "停止后状态应为已停止")
    try await waitFor { kill(pid, 0) != 0 }
    let leftovers = [runDirectory.keyURL, runDirectory.pidURL, runDirectory.socketURL]
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    check(leftovers.isEmpty, "停止后应清掉 key、pid 和 socket")
    do {
        _ = try await LocalModelConnection.readyEndpoint(in: runDirectory, waitingUpTo: .milliseconds(300))
        check(false, "服务停止后不应拿到连接")
    } catch {
        check(error as? LocalModelServerError == .notRunning, "服务停止后应报告没有运行")
    }
    do {
        _ = try await LocalModelHTTPClient.send("GET", "/health", to: endpoint, timeout: .seconds(2))
        check(false, "socket 已删除时请求不应成功")
    } catch {
        check(error as? LocalModelHTTPError == .unreachable, "socket 已删除时应报告连不上")
    }

    // 上次 KEYI 异常退出留下的 helper：新实例启动时应先结束它；pid 文件指向别的程序时不能误杀
    let staleHelper = root.appendingPathComponent("Old.app/Contents/Helpers/llama/llama-server")
    try compileIdleBinary(to: staleHelper)
    let stale = Process()
    stale.executableURL = staleHelper
    try stale.run()
    let unrelated = Process()
    unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
    unrelated.arguments = ["30"]
    try unrelated.run()
    defer { if unrelated.isRunning { unrelated.terminate() } }

    let recoveryDirectory = LocalModelRunDirectory(url: root.appendingPathComponent("recovery", isDirectory: true))
    try recoveryDirectory.prepare()
    try Data(String(stale.processIdentifier).utf8).write(to: recoveryDirectory.pidURL)
    let recovering = LocalModelServer(helperURL: fakeHelper, runDirectory: recoveryDirectory, readyTimeout: .seconds(10))
    recovering.run(modelAt: model)
    try await waitFor { !stale.isRunning }
    try await waitFor { recovering.state == .ready(model) }
    check(!stale.isRunning, "新实例启动时应结束上次留下的 helper")
    recovering.stop()

    try Data(String(unrelated.processIdentifier).utf8).write(to: recoveryDirectory.pidURL)
    recovering.run(modelAt: model)
    try await waitFor { recovering.state == .ready(model) }
    check(unrelated.isRunning, "pid 文件指向的不是自带 helper 时不应结束它")
    recovering.stop()

    // 反复崩溃：重启到上限后放弃，并把失败原因留给子进程
    let crashingHelper = root.appendingPathComponent("crashing-llama-server")
    let launches = root.appendingPathComponent("launches")
    try writeExecutable("#!/bin/sh\necho launch >> '\(launches.path)'\nexit 1\n", to: crashingHelper)
    let crashDirectory = LocalModelRunDirectory(url: root.appendingPathComponent("crash", isDirectory: true))
    let crashing = LocalModelServer(
        helperURL: crashingHelper,
        runDirectory: crashDirectory,
        readyTimeout: .seconds(10),
        restartDelay: .milliseconds(10)
    )
    crashing.run(modelAt: model)
    try await waitFor { crashing.state == .failed(.failed) }
    let launchCount = try String(contentsOf: launches, encoding: .utf8)
        .split(separator: "\n").count
    check(launchCount == LocalModelServer.maxConsecutiveFailures, "应连续尝试 \(LocalModelServer.maxConsecutiveFailures) 次后放弃")
    check(crashDirectory.recordedFailure() == .failed, "放弃后应记下失败原因")
    do {
        _ = try await LocalModelConnection.readyEndpoint(in: crashDirectory, waitingUpTo: .seconds(1))
        check(false, "启动失败后不应拿到连接")
    } catch {
        check(error as? LocalModelServerError == .failed, "启动失败后应立即报告失败，不必等到超时")
    }
    crashing.stop()
    check(crashDirectory.recordedFailure() == nil, "主动停止后不应再报告上次的启动失败")

    // 缺少 helper
    let missing = LocalModelServer(
        helperURL: root.appendingPathComponent("absent"),
        runDirectory: LocalModelRunDirectory(url: root.appendingPathComponent("missing", isDirectory: true))
    )
    missing.run(modelAt: model)
    check(missing.state == .failed(.helperMissing), "缺少自带 helper 时应报告组件缺失")

    return checks
}

private func throwsUnsafe(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch {
        return error as? LocalModelServerError == .runDirectoryUnsafe
    }
}

private func flag(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// 复制系统二进制会被签名校验杀掉，所以现编一个只会空转的程序充当遗留的 helper。
private func compileIdleBinary(to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let source = url.deletingLastPathComponent().appendingPathComponent("idle.c")
    try Data("#include <unistd.h>\nint main(void) { for (;;) pause(); }\n".utf8).write(to: source)
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    compiler.arguments = ["-o", url.path, source.path]
    try compiler.run()
    compiler.waitUntilExit()
    guard compiler.terminationStatus == 0 else { fatalError("无法编译遗留 helper 替身") }
}

private func writeExecutable(_ script: String, to url: URL) throws {
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

@MainActor
private func waitFor(
    timeout: Duration = .seconds(15),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { fatalError("等待本地模型服务状态超时") }
        try await Task.sleep(for: .milliseconds(50))
    }
}
