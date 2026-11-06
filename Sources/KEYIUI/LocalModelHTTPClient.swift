import Foundation
import Network

/// 一条本地模型服务的连接地址：只在当前用户 0700 运行目录里的 UNIX socket，加每次启动随机生成的密钥。
struct LocalModelEndpoint: Sendable, Equatable {
    let socketPath: String
    let apiKey: String
}

struct LocalModelHTTPResponse: Sendable {
    let status: Int
    let body: Data
}

enum LocalModelHTTPError: LocalizedError, Equatable {
    case unreachable
    case timeout
    case invalidResponse

    var errorDescription: String? {
        let strings = InterfaceStrings.current
        return switch self {
        case .unreachable: strings.localModelUnreachable
        case .timeout: strings.localModelTimeout
        case .invalidResponse: strings.localModelInvalidResponse
        }
    }
}

/// 走 UNIX socket 的最小 HTTP/1.1 客户端，只够和自带的 llama-server 说话：
/// 每次请求一条连接，响应按 Content-Length 读完即止。
enum LocalModelHTTPClient {
    static func send(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        to endpoint: LocalModelEndpoint,
        timeout: Duration
    ) async throws -> LocalModelHTTPResponse {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n"
        head += "Authorization: Bearer \(endpoint.apiKey)\r\nConnection: close\r\n"
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var request = Data(head.utf8)
        if let body { request.append(body) }

        let exchange = HTTPExchange(
            connection: NWConnection(to: .unix(path: endpoint.socketPath), using: .tcp),
            request: request
        )
        return try await withTaskCancellationHandler {
            try await exchange.run(timeout: timeout)
        } onCancel: {
            exchange.finish(.failure(CancellationError()))
        }
    }

    /// 完整响应返回结果；还没收全返回 nil。`atEnd` 表示对端已关闭，不会再有数据。
    static func parse(_ data: Data, atEnd: Bool) throws -> LocalModelHTTPResponse? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            if atEnd { throw LocalModelHTTPError.invalidResponse }
            return nil
        }
        guard let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            throw LocalModelHTTPError.invalidResponse
        }
        let lines = head.components(separatedBy: "\r\n")
        let statusParts = lines[0].split(separator: " ")
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."),
              let status = Int(statusParts[1]) else {
            throw LocalModelHTTPError.invalidResponse
        }
        var contentLength: Int?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if name == "transfer-encoding", value.lowercased() != "identity" {
                throw LocalModelHTTPError.invalidResponse
            }
            if name == "content-length" {
                guard let length = Int(value), length >= 0 else {
                    throw LocalModelHTTPError.invalidResponse
                }
                contentLength = length
            }
        }
        let body = data[separator.upperBound...]
        guard let contentLength else {
            return atEnd ? LocalModelHTTPResponse(status: status, body: Data(body)) : nil
        }
        guard body.count >= contentLength else {
            if atEnd { throw LocalModelHTTPError.invalidResponse }
            return nil
        }
        return LocalModelHTTPResponse(status: status, body: Data(body.prefix(contentLength)))
    }
}

private final class HTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let queue = DispatchQueue(label: "com.keyi.input-translator.local-model-http")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalModelHTTPResponse, Error>?
    private var pending: Result<LocalModelHTTPResponse, Error>?
    private var received = Data()

    init(connection: NWConnection, request: Data) {
        self.connection = connection
        self.request = request
    }

    func run(timeout: Duration) async throws -> LocalModelHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pending {
                lock.unlock()
                continuation.resume(with: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()

            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { [self] error in
                        if error != nil {
                            finish(.failure(LocalModelHTTPError.unreachable))
                        } else {
                            receive()
                        }
                    })
                case .waiting, .failed:
                    finish(.failure(LocalModelHTTPError.unreachable))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            let seconds = Double(timeout.components.seconds)
                + Double(timeout.components.attoseconds) / 1e18
            queue.asyncAfter(deadline: .now() + seconds) { [self] in
                finish(.failure(LocalModelHTTPError.timeout))
            }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, isComplete, error in
            if let data { received.append(data) }
            let atEnd = isComplete || error != nil
            do {
                if let response = try LocalModelHTTPClient.parse(received, atEnd: atEnd) {
                    finish(.success(response))
                } else {
                    receive()
                }
            } catch {
                finish(.failure(received.isEmpty ? LocalModelHTTPError.unreachable : error))
            }
        }
    }

    /// 只有第一次生效；之后的超时、取消或连接状态变化都被忽略。
    func finish(_ result: Result<LocalModelHTTPResponse, Error>) {
        lock.lock()
        guard pending == nil else {
            lock.unlock()
            return
        }
        pending = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        connection.cancel()
        continuation?.resume(with: result)
    }
}
