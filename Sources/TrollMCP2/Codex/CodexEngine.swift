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
                    self.rpc.request("thread/start", params: [:]) { [weak self] result in
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
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = CodexKernel.codexHome
        env["HOME"] = CodexKernel.codexHome
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

            case "item/started":
                if let item = params["item"] as? [String: Any],
                   let type = item["type"] as? String {
                    DispatchQueue.main.async { self.statusSink?("Codex: \(type)") }
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

        rpc.onServerRequest = { [weak self] _, method, params in
            guard let self else { return [:] }
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
}
