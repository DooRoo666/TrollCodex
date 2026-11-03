import Foundation

// MARK: - Thread 持久化
//
// 为什么需要它：Codex 的上下文活在 `thread` 里，thread 只存在于 codex 子进程里。
// 旧实现每个请求 new 一个 CodexEngine（内含新 CodexRPC → 新进程 → 新 thread），
// 于是"上一轮聊了什么"根本传不过去，UI 看着有历史、模型其实每轮从零开始。
// 现在 threadId 按会话落盘，重启 App / 换会话都能接着用。

struct CodexThreadRecord: Codable {
    var conversationKey: String
    var threadId: String
    var updatedAt: Double
}

final class CodexThreadStore {
    static let shared = CodexThreadStore()

    private let url: URL
    private let lock = NSLock()
    private var records: [String: CodexThreadRecord] = [:]

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent("trollcodex-threads.json")
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([CodexThreadRecord].self, from: data) {
            for r in list { records[r.conversationKey] = r }
        }
    }

    var filePath: String { url.path }

    func threadId(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return records[key]?.threadId
    }

    func set(threadId: String, for key: String) {
        lock.lock()
        records[key] = CodexThreadRecord(conversationKey: key,
                                        threadId: threadId,
                                        updatedAt: Date().timeIntervalSince1970)
        persistLocked()
        lock.unlock()
    }

    func remove(_ key: String) {
        lock.lock()
        records.removeValue(forKey: key)
        persistLocked()
        lock.unlock()
    }

    /// 会话被删除 / 需要"重新开始一个干净上下文"时调用
    func reset() {
        lock.lock()
        records.removeAll()
        persistLocked()
        lock.unlock()
    }

    /// 状态页展示用：当前持久化了哪些会话
    func debugKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return records.keys.sorted()
    }

    private func persistLocked() {
        let list = Array(records.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - 工具卡事件（显示用，不触发二次执行）
//
// Codex 自己就把工具跑完了（dynamicTools 回调），所以这里的卡片只是"把发生过的事画出来"。
// 千万别把它们再交给 Models 的 toolCalls 分支去执行——那会重复执行一遍。

enum CodexToolCardStatus: String {
    case running, completed, failed
}

struct CodexToolCard {
    let id: String
    let name: String
    var args: String?
    var result: String?
    var status: CodexToolCardStatus
    var duration: Double?
}

// MARK: - Turn 句柄

final class CodexTurnHandle {
    let id = UUID()
    fileprivate var cancelled = false
}

// MARK: - 常驻运行时
//
// 一个 App 只跑一个 `codex app-server` 子进程：
//   · 首次发消息启动，之后常驻（省掉每轮 1-3s 的进程+thread 冷启动）
//   · thread 按 conversationKey 复用，上下文真正连续
//   · 单 turn 串行（UI 本来就是一次一个请求），避免同一进程内多 turn 交叉污染事件流
//   · 进程死了 → 下一轮自动重建，并把 threadId 丢掉重开（可解释，不静默挂死）

final class CodexRuntime {
    static let shared = CodexRuntime()

    private let rpc = CodexRPC()
    private let workQueue = DispatchQueue(label: "trollcodex.runtime", qos: .userInitiated)
    private let lock = NSLock()
    private var current: CodexTurn?

    /// 空闲超时：一轮 turn 最长等多久（Codex 长任务放量，30 分钟）
    var turnTimeout: TimeInterval = 1800

    private init() {}

    var isProcessAlive: Bool { rpc.isRunning }

    // MARK: 提交一轮

    func submit(conversationKey: String,
                prompt: String,
                instructions: String?,
                images: [String] = [],
                config: ModelConfig?,
                approvalMode: CodexTurnApprovalMode = .inherit,
                onStatus: ((String) -> Void)?,
                onDelta: ((String) -> Void)?,
                onThinking: ((String) -> Void)?,
                onToolCard: ((CodexToolCard) -> Void)?,
                completion: @escaping (Result<(text: String, thinking: String?), Error>) -> Void) -> CodexTurnHandle? {

        let turn = CodexTurn(key: conversationKey,
                             instructions: instructions,
                             prompt: prompt,
                             images: images,
                             config: config,
                             approvalMode: approvalMode,
                             onStatus: onStatus,
                             onDelta: onDelta,
                             onThinking: onThinking,
                             onToolCard: onToolCard,
                             completion: completion)

        lock.lock()
        let busy = current != nil
        if !busy { current = turn }
        lock.unlock()

        if busy {
            completion(.failure(CodexRPCError(code: -2, message: "上一轮还没结束")))
            return nil
        }

        workQueue.async { [weak self] in
            self?.start(turn)
        }
        return turn.handle
    }

    func cancel(_ handle: CodexTurnHandle) {
        lock.lock()
        let turn = current
        let match = (turn?.handle.id == handle.id)
        if match { turn?.handle.cancelled = true }
        lock.unlock()
        guard match, let turn else { return }
        if let threadId = turn.threadId {
            rpc.request("turn/interrupt", params: ["threadId": threadId])
        }
        finish(turn, .failure(CodexRPCError(code: -4, message: "已取消")))
    }

    func shutdown() {
        lock.lock()
        let turn = current
        current = nil
        lock.unlock()
        if let turn { finish(turn, .failure(CodexRPCError(code: -1, message: "运行时已关闭"))) }
        rpc.stop()
    }

    // MARK: 启动 / 线程解析

    private func start(_ turn: CodexTurn) {
        do {
            try ensureRunning()
        } catch {
            finish(turn, .failure(error))
            return
        }

        turn.onStatus?("Codex 就绪 · 处理中…")

        if let existing = CodexThreadStore.shared.threadId(for: turn.key) {
            turn.threadId = existing
            startTurn(turn, threadId: existing)
            return
        }

        // 新会话：带上系统提示词（协议支持则走 baseInstructions，不支持则降级为消息前缀）
        turn.onStatus?("创建会话…")
        startThread(instructions: turn.instructions) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                // 进程可能刚崩：丢掉缓存的 threadId，下次重开
                CodexThreadStore.shared.remove(turn.key)
                self.finish(turn, .failure(error))
            case .success(let threadId):
                turn.threadId = threadId
                CodexThreadStore.shared.set(threadId: threadId, for: turn.key)
                self.startTurn(turn, threadId: threadId)
            }
        }
    }

    private func ensureRunning() throws {
        if rpc.isRunning { return }
        guard let binary = CodexKernel.binaryPath else {
            throw CodexRPCError(code: -5, message: "找不到 codex 运行时：请在设置里安装，或用 NanoCodex 复用现有运行时")
        }
        CodexKernel.ensureConfig()
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = CodexKernel.homePath
        env["HOME"] = CodexKernel.homePath
        env["PATH"] = (env["PATH"] ?? "") + ":/usr/bin:/bin"
        // v7.1.290：有 API Key 就同时给环境变量（部分 codex 版本只读 env，不读 auth.json）
        if let key = CodexKernel.apiKey {
            env["OPENAI_API_KEY"] = key
        }
        wire()
        try rpc.start(binary: binary, environment: env)
        NetworkLog.shared.log("[codex] app-server started: \(binary)")
    }

    /// `thread/start`：先带 instructions 试一次，参数不被接受就自动降级重试
    private func startThread(instructions: String?, completion: @escaping (Result<String, Error>) -> Void) {
        let specs = CodexEngine.dynamicToolSpecs()
        var rich: [String: Any] = ["cwd": NSHomeDirectory()]
        if !specs.isEmpty { rich["dynamicTools"] = specs }
        let trimmed = (instructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // 不同 codex 版本对这两个字段的支持不一致：都塞进去，被拒就整体降级
            rich["baseInstructions"] = trimmed
            rich["developerInstructions"] = trimmed
        }

        let parse: (Result<Any, Error>) -> Void = { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let value):
                let dict = value as? [String: Any] ?? [:]
                let thread = dict["thread"] as? [String: Any]
                if let id = (thread?["id"] as? String) ?? (dict["threadId"] as? String) {
                    completion(.success(id))
                } else {
                    completion(.failure(CodexRPCError(code: -3, message: "thread/start 未返回 id")))
                }
            }
        }

        rpc.request("thread/start", params: rich) { [weak self] result in
            if case .failure(let error) = result, !trimmed.isEmpty, CodexRuntime.isParamRejection(error) {
                // 降级：只用被实测验证过的最小字段集（cwd + dynamicTools）
                NetworkLog.shared.log("[codex] thread/start 拒绝 instructions 字段，降级重试")
                var minimal: [String: Any] = ["cwd": NSHomeDirectory()]
                if !specs.isEmpty { minimal["dynamicTools"] = specs }
                self?.rpc.request("thread/start", params: minimal, completion: parse)
            } else {
                parse(result)
            }
        }
    }

    static func isParamRejection(_ error: Error) -> Bool {
        guard let e = error as? CodexRPCError else { return false }
        return e.code == -32602 || e.code == -32600 || e.message.lowercased().contains("unknown")
            || e.message.lowercased().contains("invalid")
    }

    private func startTurn(_ turn: CodexTurn, threadId: String) {
        turn.onStatus?("思考中…")
        var input: [[String: Any]] = []
        for image in turn.images.prefix(4) where CodexRuntime.imagesEnabled {
            input.append(["type": "image", "url": image])
        }
        input.append(["type": "text", "text": turn.prompt])

        let params: [String: Any] = ["threadId": threadId, "input": input]
        turn.startedAt = Date()
        turn.lastActivityAt = Date()

        rpc.request("turn/start", params: params) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                // 图片项不被接受 → 去掉图片重试一次（纯文本永远可用）
                if !turn.images.isEmpty, CodexRuntime.isParamRejection(error) || error.localizedDescription.contains("input") {
                    var textOnly = params
                    textOnly["input"] = [["type": "text", "text": turn.prompt]]
                    self.rpc.request("turn/start", params: textOnly) { retry in
                        if case .failure(let e) = retry { self.finish(turn, .failure(e)) }
                    }
                    return
                }
                self.finish(turn, .failure(error))
            }
        }

        // 看门狗：长时间没有任何事件才算卡死（有事件就续命）
        scheduleWatchdog(turn)
    }

    private func scheduleWatchdog(_ turn: CodexTurn) {
        workQueue.asyncAfter(deadline: .now() + min(60, turnTimeout)) { [weak self] in
            self?.checkWatchdog(turn)
        }
    }

    private func checkWatchdog(_ turn: CodexTurn) {
        guard !turn.finished else { return }
        let idle = Date().timeIntervalSince(turn.lastActivityAt)
        if idle >= turnTimeout {
            finish(turn, .failure(CodexRPCError(code: -6, message: "Codex 长时间无响应（\(Int(idle))s），已中止")))
            return
        }
        scheduleWatchdog(turn)
    }

    private static var imagesEnabled: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Documents/trollcodex-images.txt")
    }

    // MARK: 事件分发

    private func wire() {
        rpc.onLog = { line in
            NSLog("[codex] %@", line)
            NetworkLog.shared.log("[codex] " + String(line.prefix(300)))
        }

        rpc.onNotification = { [weak self] method, params in
            self?.handleNotification(method, params)
        }

        rpc.onServerRequest = { [weak self] id, method, params in
            guard let self else { return [:] }
            return self.handleServerRequest(id: id, method: method, params: params)
        }
    }

    private func handleNotification(_ method: String, _ params: [String: Any]) {
        lock.lock()
        let turn = current
        lock.unlock()
        guard let turn, !turn.finished else { return }
        turn.lastActivityAt = Date()

        switch method {
        case "item/agentMessage/delta":
            guard let delta = params["delta"] as? String else { return }
            turn.text += delta
            DispatchQueue.main.async { turn.onDelta?(delta) }

        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            guard let delta = params["delta"] as? String else { return }
            turn.thinking += delta
            DispatchQueue.main.async { turn.onThinking?(delta) }

        case "item/started", "item/completed", "item/updated":
            guard let item = params["item"] as? [String: Any] else { return }
            emitCard(for: item, completed: method == "item/completed", turn: turn)

        case "thread/tokenUsage/updated", "token_count":
            turn.usage = Self.extractUsage(params) ?? turn.usage

        case "turn/completed":
            if turn.usage == nil { turn.usage = Self.extractUsage(params) }
            let thinking = turn.thinking.isEmpty ? nil : turn.thinking
            finish(turn, .success((text: turn.text, thinking: thinking)))

        case "error":
            let message = (params["message"] as? String) ?? (params["error"] as? String) ?? "Codex 运行错误"
            finish(turn, .failure(CodexRPCError(code: -7, message: message)))

        default:
            break
        }
    }

    /// Codex 的工具项 → 显示卡（命令 / MCP 工具 / 文件改动）
    private func emitCard(for item: [String: Any], completed: Bool, turn: CodexTurn) {
        let type = (item["type"] as? String) ?? "item"
        let itemId = (item["id"] as? String) ?? UUID().uuidString

        var name = type
        var args: String?
        var result: String?
        var failed = false

        switch type {
        case "commandExecution":
            let cmd = (item["command"] as? String) ?? ""
            name = "shell"
            args = cmd
            if let exit = item["exitCode"] as? Int {
                result = "exit=\(exit)"
                failed = exit != 0
            } else if let out = item["aggregatedOutput"] as? String {
                result = String(out.suffix(600))
            }
        case "mcpToolCall":
            let server = (item["server"] as? String) ?? "mcp"
            let tool = (item["tool"] as? String) ?? ""
            name = "\(server).\(tool)"
            if let a = item["arguments"] { args = Self.jsonText(a) }
            if let r = item["result"] { result = Self.jsonText(r) }
            if let err = item["error"], !(err is NSNull) { result = Self.jsonText(err); failed = true }
        case "fileChange":
            name = "fileChange"
            if let changes = item["changes"] as? [[String: Any]] {
                let paths = changes.compactMap { ($0["path"] as? String) ?? ($0["file"] as? String) }
                args = paths.joined(separator: "\n")
            }
        case "reasoning":
            return   // 思考走 onThinking，不画卡片
        default:
            args = Self.jsonText(item)
        }

        let card = CodexToolCard(id: itemId,
                                 name: name,
                                 args: args,
                                 result: result,
                                 status: completed ? (failed ? .failed : .completed) : .running,
                                 duration: turn.cardStart[itemId].map { Date().timeIntervalSince($0) })
        if !completed, turn.cardStart[itemId] == nil { turn.cardStart[itemId] = Date() }
        DispatchQueue.main.async { turn.onToolCard?(card) }
    }

    private func handleServerRequest(id: Int, method: String, params: [String: Any]) -> [String: Any]? {
        let turn = currentTurn()

        if method == "item/tool/call" {
            handleDynamicToolCall(id: id, params: params)
            return nil      // 异步回包
        }

        if CodexRuntime.isApprovalMethod(method) && turn?.approvalMode == .denyAll {
            // 一次性任务（压缩/摘要）：不写文件、不弹框，直接拒
            return ["decision": CodexApprovalDecision.denied.rawValue]
        }

        if CodexRuntime.isApprovalMethod(method) {
            let request = CodexApprovalRequest(method: method, payload: params)
            CodexApprovalCenter.shared.resolve(request) { decision in
                self.rpc.reply(id: id, result: ["decision": decision.rawValue])
            }
            return nil      // 异步回包（等用户点）
        }

        // 未知反向请求：不阻断，回空对象
        NetworkLog.shared.log("[codex] 未处理的反向请求: \(method)")
        return [:]
    }

    static func isApprovalMethod(_ method: String) -> Bool {
        // codex 各版本命名不一致：新的是 item/*/requestApproval，
        // 老的是 execCommandApproval / applyPatchApproval —— 统一按关键字兜住
        method.lowercased().contains("approval")
    }

    // MARK: 动态工具（进程内直跑 ToolRegistry）

    private func handleDynamicToolCall(id: Int, params: [String: Any]) {
        lock.lock()
        let turn = current
        lock.unlock()

        let invoked = (params["tool"] as? String) ?? ""
        let name = CodexEngine.originalToolName(invoked)
        let args = (params["arguments"] as? [String: Any]) ?? [:]
        let cardId = "dyn-\(id)"
        let started = Date()

        if let turn {
            turn.lastActivityAt = Date()
            let card = CodexToolCard(id: cardId, name: name,
                                     args: Self.jsonText(args), result: nil,
                                     status: .running, duration: nil)
            DispatchQueue.main.async { turn.onToolCard?(card) }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let response: [String: Any]
            let failed: Bool
            let summary: String
            do {
                let out = try ToolRegistry.shared.dispatch(name: name, params: args)
                let text = Self.jsonText(out)
                response = ["contentItems": [["type": "inputText", "text": text]], "success": true]
                failed = false
                summary = String(text.prefix(600))
            } catch {
                let text = "ERROR: \(error.localizedDescription)"
                response = ["contentItems": [["type": "inputText", "text": text]], "success": false]
                failed = true
                summary = text
            }

            if let owner = self?.currentTurn() {
                let card = CodexToolCard(id: cardId, name: name, args: nil, result: summary,
                                         status: failed ? .failed : .completed,
                                         duration: Date().timeIntervalSince(started))
                DispatchQueue.main.async { owner.onToolCard?(card) }
            }
            self?.rpc.reply(id: id, result: response)
        }
    }

    private func currentTurn() -> CodexTurn? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    // MARK: 收尾

    private func finish(_ turn: CodexTurn, _ result: Result<(text: String, thinking: String?), Error>) {
        lock.lock()
        if turn.finished { lock.unlock(); return }
        turn.finished = true
        if current === turn { current = nil }
        let usage = turn.usage
        let startedAt = turn.startedAt
        lock.unlock()

        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        switch result {
        case .success(let payload):
            // Codex-only 场景下模型库可能为空（用户只在 codex 里登录）——config 可选，没有就不记 usage
            if let cfg = turn.config {
                UsageRecorder.shared.end(config: cfg, ok: true, elapsedMs: elapsed, usage: usage)
            }
            DispatchQueue.main.async { turn.completion(.success(payload)) }
        case .failure(let error):
            if let cfg = turn.config {
                UsageRecorder.shared.end(config: cfg, ok: false, elapsedMs: elapsed,
                                         error: error.localizedDescription, usage: usage)
            }
            DispatchQueue.main.async { turn.completion(.failure(error)) }
        }
    }

    // MARK: 小工具

    static func jsonText(_ object: Any) -> String {
        if let dict = object as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let array = object as? [Any],
           let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: object)
    }

    /// 兼容 codex 各版本的 usage 形态
    static func extractUsage(_ params: [String: Any]) -> [String: Any]? {
        let candidates: [[String: Any]?] = [
            params["usage"] as? [String: Any],
            (params["turn"] as? [String: Any])?["usage"] as? [String: Any],
            (params["tokenUsage"] as? [String: Any]),
            (params["info"] as? [String: Any])?["usage"] as? [String: Any]
        ]
        for case let dict? in candidates {
            let input = (dict["input_tokens"] as? Int) ?? (dict["inputTokens"] as? Int)
                ?? (dict["prompt_tokens"] as? Int) ?? (dict["total_input_tokens"] as? Int)
            let output = (dict["output_tokens"] as? Int) ?? (dict["outputTokens"] as? Int)
                ?? (dict["completion_tokens"] as? Int) ?? (dict["total_output_tokens"] as? Int)
            guard input != nil || output != nil else { continue }
            let i = input ?? 0
            let o = output ?? 0
            return ["prompt_tokens": i, "completion_tokens": o, "total_tokens": i + o]
        }
        return nil
    }
}

// MARK: - 一轮 turn 的状态

enum CodexTurnApprovalMode {
    /// 走全局策略（设置/文件配置，默认弹框）
    case inherit
    /// 一切审批直接拒绝（一次性摘要任务用，不打扰用户）
    case denyAll
}

final class CodexTurn {
    let handle = CodexTurnHandle()
    let key: String
    let instructions: String?
    let prompt: String
    let images: [String]
    let config: ModelConfig?
    let approvalMode: CodexTurnApprovalMode

    let onStatus: ((String) -> Void)?
    let onDelta: ((String) -> Void)?
    let onThinking: ((String) -> Void)?
    let onToolCard: ((CodexToolCard) -> Void)?
    let completion: (Result<(text: String, thinking: String?), Error>) -> Void

    var threadId: String?
    var text = ""
    var thinking = ""
    var usage: [String: Any]?
    var cardStart: [String: Date] = [:]
    var startedAt = Date()
    var lastActivityAt = Date()
    var finished = false

    init(key: String,
         instructions: String?,
         prompt: String,
         images: [String],
         config: ModelConfig?,
         approvalMode: CodexTurnApprovalMode,
         onStatus: ((String) -> Void)?,
         onDelta: ((String) -> Void)?,
         onThinking: ((String) -> Void)?,
         onToolCard: ((CodexToolCard) -> Void)?,
         completion: @escaping (Result<(text: String, thinking: String?), Error>) -> Void) {
        self.key = key
        self.instructions = instructions
        self.prompt = prompt
        self.images = images
        self.config = config
        self.approvalMode = approvalMode
        self.onStatus = onStatus
        self.onDelta = onDelta
        self.onThinking = onThinking
        self.onToolCard = onToolCard
        self.completion = completion
    }
}
