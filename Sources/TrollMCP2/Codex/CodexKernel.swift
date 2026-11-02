import Foundation

/// 内核选择与运行时配置。
/// 默认仍走 OpenAIClient；只有当用户显式切到 Codex 或环境变量 TROLLCODEX=1 时才启用。
enum CodexKernel {
    private static let defaultsKey = "trollcodex.kernel.enabled"

    /// 免 UI 开关：Documents/trollcodex-kernel.txt 内容写 codex 即启用
    static var flagFilePath: String { NSHomeDirectory() + "/Documents/trollcodex-kernel.txt" }

    static var isEnabled: Bool {
        get {
            if ProcessInfo.processInfo.environment["TROLLCODEX"] == "1" { return true }
            if let raw = try? String(contentsOfFile: flagFilePath, encoding: .utf8) {
                return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex"
            }
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
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
    static func ensureConfig() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: homePath, withIntermediateDirectories: true)
        migrateAuthIfNeeded()
        let path = homePath + "/config.toml"
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
    static func migrateAuthIfNeeded() {
        let fm = FileManager.default
        let dst = homePath + "/auth.json"
        guard !fm.fileExists(atPath: dst) else { return }
        let candidates = [
            "/var/mobile/.codex/auth.json",
            "/private/var/mobile/.codex/auth.json",
            NSHomeDirectory() + "/.codex/auth.json"
        ]
        for src in candidates where fm.fileExists(atPath: src) {
            try? fm.copyItem(atPath: src, toPath: dst)
            if fm.fileExists(atPath: dst) { return }
        }
    }
}
