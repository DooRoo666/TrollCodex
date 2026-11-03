import Foundation

/// 内核运行时配置。
///
/// Codex 是**唯一内核**：没有 OpenAI 回退分支，也没有开关（`isEnabled` 恒 true，只留给
/// 旧的 `handoffActiveRequestToBackground` 判断用）。找不到运行时 = 直接报错，不静默降级。
enum CodexKernel {
    static var isEnabled: Bool { true }

    /// codex 可执行文件位置（唯一来源：随包内置）
    /// 顺序：调试用环境变量 → 包内 CodexRuntime/codex → Documents/codex/codex（手工投放口）
    static var binaryCandidates: [String] {
        var list: [String] = []
        if let env = ProcessInfo.processInfo.environment["CODEX_BIN"], !env.isEmpty { list.append(env) }
        list.append(Bundle.main.bundlePath + "/CodexRuntime/codex")
        list.append(NSHomeDirectory() + "/Documents/codex/codex")
        return list
    }

    static var binaryPath: String? {
        let fm = FileManager.default
        for candidate in binaryCandidates where fm.fileExists(atPath: candidate) {
            // 安装/解包后可能丢可执行位（bundle 内文件不一定保留），这里补一次再判
            if !fm.isExecutableFile(atPath: candidate) {
                _ = chmod(candidate, 0o755)
            }
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
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

extension CodexKernel {
    /// 首次运行时写最小 config.toml：把本 App 注册成 Codex 的 MCP 工具服务端。
    /// 仅当 `Documents/trollcodex-mcp.txt` 存在时注册——那是"给外部客户端复用工具"的可选功能，
    /// **不是内核通道的降级**：内核工具走 dynamicTools，与这里无关。
    static var mcpOptInPath: String { NSHomeDirectory() + "/Documents/trollcodex-mcp.txt" }

    static func ensureConfig() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: homePath, withIntermediateDirectories: true)
        migrateAuthIfNeeded()

        let path = homePath + "/config.toml"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""

        guard fm.fileExists(atPath: mcpOptInPath) else {
            if existing.contains("# TrollCodex 自动生成") {
                try? fm.removeItem(atPath: path)
            }
            return
        }
        if existing.contains("[mcp_servers.trollagent]") { return }

        let exeName = (Bundle.main.infoDictionary?["CFBundleExecutable"] as? String) ?? "TrollAgent"
        let exe = Bundle.main.bundlePath + "/" + exeName
        let block = """
        # TrollCodex 自动生成
        [mcp_servers.trollagent]
        command = "\(exe)"
        args = ["--codex-mcp"]
        startup_timeout_sec = 30.0

        """
        try? (block + existing).write(toFile: path, atomically: true, encoding: .utf8)
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
