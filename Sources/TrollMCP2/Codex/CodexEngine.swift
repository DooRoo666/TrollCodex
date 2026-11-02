import Foundation

/// Codex 内核：用 `codex app-server` 取代 OpenAIClient 的模型调用。
/// 工具由 Codex 自己通过 MCP 调（见 CodexMCPServer），所以这里只负责：
/// 起进程 → 开 thread → 发 turn → 把流式事件翻成 UI 回调 → turn 结束返回最终文本。
final class CodexEngine: ChatEngine {
    var onAuthCorrected: ((String) -> Void)?
    var currentReasoningLevel: Int = 0
    private(set) var isStreamingInFlight = false

    /// 审批策略：nil = 自动通过；返回 nil 表示拒绝
    var approvalHandler: ((_ method: String, _ params: [String: Any]) -> [String: Any]?)?

    private let config: ModelConfig
    private let rpc = CodexRPC()
    private let queue = DispatchQueue(label: "codex.engine")
    private var threadID: String?
    private var assistantText = ""
    private var thinkingText = ""
    private var completion: ((Result<ChatResult, Error>) -> Void)?

    init(config: ModelConfig) {
        self.config = config
        wire()
    }

    deinit { rpc.stop() }

    // MARK: - ChatEngine

    func send(messages: [ChatMessage],
              compactSource: [ChatMessage],
              tools: [[String: Any]]?,
              onStatus: ((String) -> Void)?,
              onDelta: ((String) -> Void)?,
              onThinking: ((String) -> Void)?,
              onCompacted: ((String) -> Void)?,
              completion: @escaping (Result<ChatResult, Error>) -> Void) {
        guard !isStreamingInFlight else {
            completion(.failure(CodexRPCError(code: -2, message: "上一轮还没结束")))
            return
        }

        isStreamingInFlight = true
        assistantText = ""
        thinkingText = ""
        self.completion = completion
        self.deltaSink = onDelta
        self.thinkingSink = onThinking
        self.statusSink = onStatus
        self.extraSink = onCompacted

        let prompt = Self.lastUserText(in: messages)
        onStatus?("Codex 启动中…")

        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.ensureRunning()
                if let id = self.threadID {
                    self.startTurn(threadID: id, prompt: prompt, onStatus: onStatus)
                } else {
                    onStatus?("创建会话…")
                    self.rpc.request("thread/start", params: self.threadStartParams()) { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case .failure(let error):
                            self.finish(.failure(error))
                        case .success(let value):
                            let dict = value as? [String: Any] ?? [:]
                            let thread = dict["thread"] as? [String: Any]
                            let id = (thread?["id"] as? String) ?? (dict["threadId"] as? String)
                            guard let id else {
                                self.finish(.failure(CodexRPCError(code: -3, message: "thread/start 未返回 id")))
                                return
                            }
                            self.threadID = id
                            self.startTurn(threadID: id, prompt: prompt, onStatus: onStatus)
                        }
                    }
                }
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    func cancel() {
        if let id = threadID {
            rpc.request("turn/interrupt", params: ["threadId": id])
        }
        finish(.failure(CodexRPCError(code: -4, message: "已取消")))
    }

    // MARK: - 内部

    private func ensureRunning() throws {
        if rpc.isRunning { return }
        guard let binary = CodexKernel.binaryPath else {
            throw CodexRPCError(code: -5, message: "找不到 codex 运行时，请先在设置里安装")
        }
        CodexKernel.ensureConfig()
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = CodexKernel.homePath
        env["HOME"] = CodexKernel.homePath
        try rpc.start(binary: binary, environment: env)
    }

    private func startTurn(threadID: String, prompt: String, onStatus: ((String) -> Void)?) {
        onStatus?("思考中…")
        let input: [[String: Any]] = [["type": "text", "text": prompt]]
        rpc.request("turn/start", params: ["threadId": threadID, "input": input]) { [weak self] result in
            if case .failure(let error) = result { self?.finish(.failure(error)) }
        }
    }

    private func wire() {
        rpc.onLog = { line in NSLog("[codex] %@", line) }

        rpc.onNotification = { [weak self] method, params in
            guard let self else { return }
            switch method {
            case "item/agentMessage/delta":
                guard let delta = params["delta"] as? String else { return }
                self.assistantText += delta
                DispatchQueue.main.async { self.deltaSink?(delta) }

            case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
                guard let delta = params["delta"] as? String else { return }
                self.thinkingText += delta
                DispatchQueue.main.async { self.thinkingSink?(delta) }

            case "item/started", "item/completed":
                // 工具卡片：命令 / MCP 工具调用 / 文件改动都走这里，先以状态行呈现
                if let item = params["item"] as? [String: Any] {
                    let label = Self.describe(item)
                    let prefix = method == "item/completed" ? "✓ " : "▶ "
                    DispatchQueue.main.async { self.statusSink?(prefix + label) }
                }

            case "turn/completed":
                let thinking = self.thinkingText.isEmpty ? nil : self.thinkingText
                self.finish(.success(.text(self.assistantText, thinking: thinking)))

            case "error":
                let message = (params["message"] as? String) ?? "Codex 运行错误"
                self.finish(.failure(CodexRPCError(code: -6, message: message)))

            default:
                break
            }
        }

        rpc.onServerRequest = { [weak self] id, method, params in
            guard let self else { return [:] }
            if method == "item/tool/call" {
                self.handleDynamicToolCall(id: id, params: params)
                return nil      // 异步回包
            }
            if let handler = self.approvalHandler { return handler(method, params) }
            // 默认：全部放行（个人研究用途；正式版应接 UI 确认框）
            switch method {
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                return ["decision": "approved"]
            default:
                return [:]
            }
        }
    }

    private var deltaSink: ((String) -> Void)?
    private var thinkingSink: ((String) -> Void)?
    private var statusSink: ((String) -> Void)?
    private var extraSink: ((String) -> Void)?

    private func finish(_ result: Result<ChatResult, Error>) {
        isStreamingInFlight = false
        let callback = completion
        completion = nil
        DispatchQueue.main.async { callback?(result) }
    }

    static func lastUserText(in messages: [ChatMessage]) -> String {
        let userMessages = messages.filter { $0.role == "user" }
        return userMessages.last?.content ?? ""
    }

    static func describe(_ item: [String: Any]) -> String {
        let type = (item["type"] as? String) ?? "item"
        switch type {
        case "commandExecution":
            let cmd = (item["command"] as? String) ?? ""
            let short = cmd.count > 80 ? String(cmd.prefix(80)) + "…" : cmd
            if let code = item["exitCode"] as? Int { return "命令 \(short) → \(code)" }
            return "命令 \(short)"
        case "mcpToolCall":
            let server = (item["server"] as? String) ?? "mcp"
            let tool = (item["tool"] as? String) ?? ""
            return "工具 \(server).\(tool)"
        case "fileChange": return "文件改动"
        case "reasoning":  return "推理"
        case "agentMessage": return "回复"
        default: return type
        }
    }
}

// MARK: - 动态工具（进程内，不经 MCP/子进程）

extension CodexEngine {
    func threadStartParams() -> [String: Any] {
        var params: [String: Any] = ["cwd": NSHomeDirectory()]
        let specs = Self.dynamicToolSpecs()
        if !specs.isEmpty { params["dynamicTools"] = specs }
        return params
    }

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    /// 默认只暴露"Codex 内置工具做不到"的设备能力；文件/命令/搜索交给 Codex 自己。
    static var defaultToolNames: [String] { [
        "device.info", "device.snapshot", "device.refresh_container",
        "app.status", "app.launch", "app.stop", "app.install", "app.uninstall",
        "control.screenshot", "control.tap_text", "control.tap_selector",
        "control.type_text", "control.find",
        "browser.navigate", "browser.snapshot", "browser.text", "browser.click",
        "injection.list", "injection.status", "injection.enable", "injection.disable",
        "ipa.inspect", "app.decrypt", "app.entitlements",
        "ocr.image", "reminder", "location.get",
        "shell.exec"   // 先用它做兜底；确认 Codex 自带 shell 在 iOS 可用后删掉
    ] }

    /// Documents/trollcodex-tools.txt：每行一个工具名；文件不存在=用默认表，空文件=全部工具
    static var toolAllowlist: [String]? {
        let path = NSHomeDirectory() + "/Documents/trollcodex-tools.txt"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return defaultToolNames
        }
        let lines = raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return lines.isEmpty ? nil : lines
    }

    static func dynamicToolSpecs() -> [[String: Any]] {
        let allow = toolAllowlist.map(Set.init)
        let defs = ToolRegistry.shared.enabledDefinitions.filter { def in
            // 子代理已并入 Codex，不再作为独立工具暴露
            if def.name.lowercased().hasPrefix("subagent") { return false }
            guard let allow else { return true }
            return allow.contains(def.name)
        }
        return defs.map { def in
            var props: [String: Any] = [:]
            for (key, desc) in def.parameters {
                props[key] = ["type": "string", "description": desc]
            }
            return [
                "type": "function",
                "name": sanitize(def.name),
                "description": def.summary,
                "inputSchema": ["type": "object", "properties": props]
            ]
        }
    }

    static func originalToolName(_ sanitized: String) -> String {
        for def in ToolRegistry.shared.enabledDefinitions where sanitize(def.name) == sanitized {
            return def.name
        }
        return sanitized
    }

    /// item/tool/call -> 在 App 进程内直接跑 ToolRegistry，结果回给 Codex
    func handleDynamicToolCall(id: Int, params: [String: Any]) {
        let invoked = (params["tool"] as? String) ?? ""
        let name = Self.originalToolName(invoked)
        let args = (params["arguments"] as? [String: Any]) ?? [:]
        DispatchQueue.main.async { self.statusSink?("▶ 工具 \(name)") }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let response: [String: Any]
            do {
                let out = try ToolRegistry.shared.dispatch(name: name, params: args)
                let text = Self.jsonText(out)
                response = ["contentItems": [["type": "inputText", "text": text]], "success": true]
            } catch {
                response = ["contentItems": [["type": "inputText", "text": "ERROR: \(error.localizedDescription)"]], "success": false]
            }
            DispatchQueue.main.async { self?.statusSink?("✓ 工具 \(name)") }
            self?.rpc.reply(id: id, result: response)
        }
    }

    static func jsonText(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: object)
        }
        return text
    }
}
