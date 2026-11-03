import Foundation

/// 内核选择与运行时配置。
/// 默认：检测到 codex 运行时就以 Codex 为内核；否则回退 OpenAIClient。
enum CodexKernel {
    private static let defaultsKey = "trollcodex.kernel.enabled"

    /// 免 UI 开关：Documents/trollcodex-kernel.txt 内容写 codex 即启用
    static var flagFilePath: String { NSHomeDirectory() + "/Documents/trollcodex-kernel.txt" }

    /// Codex 是唯一内核，没有 OpenAI 回退通道。
    static var isEnabled: Bool {
        get { true }
        set { }
    }

    /// codex 可执行文件候选路径（按顺序探测）
    static var binaryCandidates: [String] {
        var list: [String] = []
        if let env = ProcessInfo.processInfo.environment["CODEX_BIN"], !env.isEmpty { list.append(env) }
        list.append(Bundle.main.bundlePath + "/CodexRuntime/codex")
        list.append(Bundle.main.bundlePath + "/Frameworks/codex")
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            list.append(support.appendingPathComponent("NanoCodex/runtimes/codex/var/jb/usr/libexec/codex/codex").path)
            list.append(support.appendingPathComponent("TrollCodex/codex").path)
        }
        list.append("/var/jb/usr/libexec/codex/codex")
        list.append("/var/mobile/Documents/codex/codex")
        return list
    }

    static var binaryPath: String? {
        binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// CODEX_HOME：必须是 app 可写目录，不能给 /var/mobile（codex 会尝试建 sqlite 状态库）
    static var homePath: String {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty { return env }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let home = base.appendingPathComponent("TrollCodexHome")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.path
    }

    static var statusDescription: String {
        guard let bin = binaryPath else { return "未找到 codex 可执行文件" }
        return "codex: \(bin)\nCODEX_HOME: \(homePath)"
    }
}

/// TrollAgent 原有内核与 Codex 内核的共同接口。
/// OpenAIClient 已经天然满足这些成员，extension 即可，无需改动原类。
protocol ChatEngine: AnyObject {
    var onAuthCorrected: ((String) -> Void)? { get set }
    var currentReasoningLevel: Int { get set }
    var isStreamingInFlight: Bool { get }
    func cancel()
    func send(messages: [ChatMessage],
              compactSource: [ChatMessage],
              tools: [[String: Any]]?,
              onStatus: ((String) -> Void)?,
              onDelta: ((String) -> Void)?,
              onThinking: ((String) -> Void)?,
              onCompacted: ((String) -> Void)?,
              completion: @escaping (Result<ChatResult, Error>) -> Void)
}

extension OpenAIClient: ChatEngine {}

/// 便于 UI 层直接问“现在能不能用 Codex”
enum CodexAvailability {
    case ready(String)
    case missingBinary
    case missingRuntime

    static func check() -> CodexAvailability {
        guard let path = CodexKernel.binaryPath else { return .missingBinary }
        return .ready(path)
    }
}

extension CodexKernel {
    /// 首次运行时写最小 config.toml：把本 App 注册成 Codex 的 MCP 工具服务端。
    /// 这样 Codex 拉起的 stdout 事件里，工具调用会以 McpToolCallThreadItem 出现。
    /// MCP 通道默认关闭；Documents/trollcodex-mcp.txt 存在时才注册（给外部客户端复用）
    static var mcpOptInPath: String { NSHomeDirectory() + "/Documents/trollcodex-mcp.txt" }

    static func ensureConfig() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: homePath, withIntermediateDirectories: true)
        migrateAuthIfNeeded()

        let path = homePath + "/config.toml"
        guard fm.fileExists(atPath: mcpOptInPath) else {
            // 清掉旧版本自动写过的 MCP 注册，避免和 dynamicTools 重复
            if let old = try? String(contentsOfFile: path, encoding: .utf8),
               old.contains("# TrollCodex 自动生成") {
                try? fm.removeItem(atPath: path)
            }
            return
        }
        guard !fm.fileExists(atPath: path) else { return }
        let exeName = (Bundle.main.infoDictionary?["CFBundleExecutable"] as? String) ?? "TrollAgent"
        let exe = Bundle.main.bundlePath + "/" + exeName
        let text = """
        # TrollCodex 自动生成
        [mcp_servers.trollagent]
        command = "\(exe)"
        args = ["--codex-mcp"]
        startup_timeout_sec = 30.0
        """
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

extension CodexKernel {
    /// 复用设备上已有的 Codex 登录态，免二次登录。
    ///
    /// v7.1.290：内置运行时之后，登录态成为唯一外部依赖。三种投喂方式（按优先级）：
    ///   1) Documents/codex-auth.json  原样当 $CODEX_HOME/auth.json（从 NanoCode 或电脑上拷过来的）
    ///   2) Documents/codex-apikey.txt 内容为 sk-... 的 API Key
    ///   3) 设备上已有的 /var/mobile/.codex/auth.json（NanoCode 装过的痕迹）
    static var apiKeyPath: String { NSHomeDirectory() + "/Documents/codex-apikey.txt" }
    static var authInboxPath: String { NSHomeDirectory() + "/Documents/codex-auth.json" }

    static var apiKey: String? {
        guard let raw = try? String(contentsOfFile: apiKeyPath, encoding: .utf8) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count > 20 else { return nil }
        return key
    }

    /// 设置页展示用的一句话状态
    static var authStatusDescription: String {
        let fm = FileManager.default
        if fm.fileExists(atPath: homePath + "/auth.json") { return "已就绪（auth.json）" }
        if apiKey != nil { return "已就绪（API Key）" }
        return "缺少登录态"
    }

    static func migrateAuthIfNeeded() {
        let fm = FileManager.default
        let dst = homePath + "/auth.json"
        guard !fm.fileExists(atPath: dst) else { return }
        let candidates = [
            authInboxPath,
            "/var/mobile/.codex/auth.json",
            "/private/var/mobile/.codex/auth.json",
            NSHomeDirectory() + "/.codex/auth.json"
        ]
        for path in candidates where fm.fileExists(atPath: path) {
            try? fm.copyItem(atPath: path, toPath: dst)
            if fm.fileExists(atPath: dst) { return }
        }
        // 只有 API Key 时，按 codex 认的格式写一份最小 auth.json
        if let key = apiKey {
            let json = "{\"OPENAI_API_KEY\": \"\(key)\"}"
            try? json.write(toFile: dst, atomically: true, encoding: .utf8)
        }
    }
}
