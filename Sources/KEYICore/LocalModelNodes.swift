import Foundation

/// 本机翻译模型的一个下载节点（PRODUCT_SCOPE 变更记录 2026-11-11：用户「需要多节点部署设置，让亚太区和美区的用户都能快捷的下载」）。
/// 各节点下的是同一 revision、同一 sha256 的文件，下完照样校验；文件名接在 `baseURL` 后面。
/// 规则与 Windows、Android 共用的 C# 库 `Windows/IME/KEYI.IME.Core/LocalModelNodes.cs` 一致。
public struct LocalModelDownloadNode: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let baseURL: String

    public init(id: String, name: String, baseURL: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
    }

    public func url(for model: LocalTranslationModel) -> URL {
        URL(string: baseURL + model.fileName)!
    }
}

/// 某个节点测速的结果：取了多少字节、用了多久；没取到就是 `error`。
public struct LocalModelNodeProbe: Equatable, Sendable {
    public let node: LocalModelDownloadNode
    public let byteCount: Int64
    public let elapsed: TimeInterval
    public let error: String?

    public init(node: LocalModelDownloadNode, byteCount: Int64, elapsed: TimeInterval, error: String?) {
        self.node = node
        self.byteCount = byteCount
        self.elapsed = elapsed
        self.error = error
    }

    public var isUsable: Bool { error == nil && byteCount > 0 }

    /// 每秒字节数（连接、跳转、首字节的等待都算在里面，所以远的节点自然排后面）。
    public var bytesPerSecond: Double {
        isUsable ? Double(byteCount) / max(elapsed, 0.001) : 0
    }

    /// 写进诊断记录的一句（与 C# 版 `NodeProbe.Describe` 同样的写法）。
    public var summary: String {
        guard isUsable else { return "\(node.name) 不能用（\(error ?? "没有数据")）" }
        return String(
            format: "%@ %.1f MB 用了 %.1f 秒（%.1f MB/s）",
            node.name, Double(byteCount) / 1_048_576, elapsed, bytesPerSecond / 1_048_576
        )
    }
}

/// 一次下载要试的节点和要不要先测速。
public struct LocalModelDownloadPlan: Equatable, Sendable {
    public let nodes: [LocalModelDownloadNode]
    public let probeFirst: Bool

    public init(nodes: [LocalModelDownloadNode], probeFirst: Bool) {
        self.nodes = nodes
        self.probeFirst = probeFirst
    }

    /// 默认：全部内置节点，先测速。
    public static var automatic: LocalModelDownloadPlan {
        LocalModelDownloadPlan(nodes: LocalModelDownloadNodes.builtIn, probeFirst: true)
    }
}

public enum LocalModelDownloadNodes {
    /// 默认：点下载时给各节点测速，从最快的下。
    public static let automatic = "auto"
    /// 用户自己部署的节点（设置里填地址）。
    public static let custom = "custom"

    public static let modelScope = LocalModelDownloadNode(
        id: "modelscope",
        name: "ModelScope",
        baseURL: "https://modelscope.cn/models/Tencent-Hunyuan/Hy-MT2-1.8B-GGUF/resolve/ef1d40b8b315575d30d1eb6579996130b8fc0bb2/"
    )
    public static let huggingFace = LocalModelDownloadNode(
        id: "huggingface",
        name: "Hugging Face",
        baseURL: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/a0c709d9fac510f2c807aa3af52872340dc37a4a/"
    )
    /// hf-mirror.com 照 Hugging Face 的路径（同一 revision）；中国大陆连不上 huggingface.co 时它能连。
    public static let hfMirror = LocalModelDownloadNode(
        id: "hf-mirror",
        name: "HF-Mirror",
        baseURL: "https://hf-mirror.com/tencent/Hy-MT2-1.8B-GGUF/resolve/a0c709d9fac510f2c807aa3af52872340dc37a4a/"
    )

    public static let builtIn: [LocalModelDownloadNode] = [modelScope, huggingFace, hfMirror]

    /// 设置里可选的值：自动、各内置节点、自建节点。
    public static let choices: [String] = [automatic] + builtIn.map(\.id) + [custom]

    public static func node(id: String?) -> LocalModelDownloadNode? {
        builtIn.first { $0.id == id }
    }

    /// 存下来的选择认不出时按自动。
    public static func normalizedChoice(_ choice: String?) -> String {
        guard let choice, choices.contains(choice) else { return automatic }
        return choice
    }

    /// 自己部署的节点地址：只收 https，末尾没有「/」就补上；模型文件名接在后面
    /// （如 https://cdn.example.com/keyi/ → https://cdn.example.com/keyi/Hy-MT2-1.8B-Q4_K_M.gguf）。
    public static func customNode(_ text: String?) -> LocalModelDownloadNode? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil,
              URL(string: trimmed) != nil else {
            return nil
        }
        let base = trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
        return LocalModelDownloadNode(id: custom, name: "自建节点", baseURL: base)
    }

    /// 这次下载按什么顺序试：自动时是全部内置节点、先测速；指定了某个节点（或自建节点）时它排第一、不测速，
    /// 不行再给其余内置节点测速、从快的接着下。自建节点地址不对时按自动处理。
    public static func plan(choice: String?, customURL: String?) -> LocalModelDownloadPlan {
        let first = choice == custom ? customNode(customURL) : node(id: choice)
        guard let first else { return .automatic }
        return LocalModelDownloadPlan(
            nodes: [first] + builtIn.filter { $0.id != first.id },
            probeFirst: false
        )
    }

    /// 测速结果排顺序：能用的按速度从快到慢；不能用的不排进去（原因另报）。
    public static func rank(_ probes: [LocalModelNodeProbe]) -> [LocalModelDownloadNode] {
        probes.filter(\.isUsable)
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.bytesPerSecond != rhs.element.bytesPerSecond
                    ? lhs.element.bytesPerSecond > rhs.element.bytesPerSecond
                    : lhs.offset < rhs.offset
            }
            .map(\.element.node)
    }
}
