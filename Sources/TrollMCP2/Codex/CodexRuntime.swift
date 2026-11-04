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
    /// 建这个 thread 时的模型+上游签名（旧记录没有该字段 → 视为 nil）
    var signature: String? = nil
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

    func set(threadId: String, for key: String, signature: String? = nil) {
        lock.lock()
        records[key] = CodexThreadRecord(conversationKey: key,
                                        threadId: threadId,
                                        updatedAt: Date().timeIntervalSince1970,
                                        signature: signature)
        persistLocked()
        lock.unlock()
    }

    /// 建这个 thread 时的模型+上游签名；换了就该重开（thread 绑定创建时的 provider）
    func signature(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return records[key]?.signature
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
    /// initialize 只做一次；进程重启后清掉
    private var handshakeDone = false

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

        // 整轮期间持有后台额度：App 退到后台时 codex 子进程才不会被立刻挂起
        // （配合 entitlements 的 com.apple.private.background-task.allowed）
        BackgroundKeeper.shared.begin(reason: "turn")

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

        // 官方协议第一步是 initialize：thread/start.dynamicTools 需要
        // capabilities.experimentalApi 授权。握手失败 = 内核不可用，直接报错。
        ensureHandshake { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(turn, .failure(error))
            case .success:
                self.beginTurn(turn)
            }
        }
    }

    private func beginTurn(_ turn: CodexTurn) {
        turn.onStatus?("Codex 就绪 · 处理中…")

        // 每轮同步一次：设置里换模型/换 Key 后，下一轮就按新配置走（config.toml + auth.json）
        CodexKernel.ensureConfig()

        // 换模型/换上游后旧 thread 不能复用（codex 的 thread 绑定创建时的 provider）
        let signature = CodexKernel.threadSignature
        if let existing = CodexThreadStore.shared.threadId(for: turn.key) {
            if CodexThreadStore.shared.signature(for: turn.key) == signature {
                turn.threadId = existing
                startTurn(turn, threadId: existing)
                return
            }
            NetworkLog.shared.log("[codex] 模型/上游已变更，重开会话 thread")
            CodexThreadStore.shared.remove(turn.key)
        }

        // 新会话：系统提示词只走 developerInstructions（保留 codex 自带 baseInstructions）
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
                CodexThreadStore.shared.set(threadId: threadId, for: turn.key, signature: signature)
                self.startTurn(turn, threadId: threadId)
            }
        }
    }

    /// initialize 握手（唯一路径，失败即报错，不换参数重试）
    ///
    /// 官方定义（app-server InitializeParams）：
    ///   { clientInfo: {name, title, version},
    ///     capabilities: { experimentalApi: bool, requestAttestation: bool, ... } }
    private func ensureHandshake(completion: @escaping (Result<Void, Error>) -> Void) {
        if handshakeDone {
            completion(.success(()))
            return
        }
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        let params: [String: Any] = [
            "clientInfo": ["name": "trollcodex", "title": "TrollCodex", "version": version],
            "capabilities": ["experimentalApi": true, "requestAttestation": false]
        ]
        rpc.request("initialize", params: params) { [weak self] result in
            switch result {
            case .success:
                self?.handshakeDone = true
                self?.rpc.notify("initialized", params: [:])
                completion(.success(()))
            case .failure(let error):
                let detail = error.localizedDescription
                NetworkLog.shared.log("[codex] initialize 失败：\(detail)")
                completion(.failure(CodexRPCError(code: -10, message: "codex 握手失败：\(detail)")))
            }
        }
    }

    private func ensureRunning() throws {
        if rpc.isRunning { return }
        guard let binary = CodexKernel.binaryPath else {
            throw CodexRPCError(code: -5, message: "找不到 codex 运行时：请在设置里安装，或用 NanoCodex 复用现有运行时")
        }
        CodexKernel.ensureConfig()
        handshakeDone = false
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = CodexKernel.homePath
        env["HOME"] = CodexKernel.homePath
        env["PATH"] = CodexKernel.homePath + "/bin"
        // iOS 上没有 /usr/bin、/bin —— 给假 PATH 只会让 codex 的 shell 工具报看不懂的错。
        // 命令执行统一走 shell.exec（TrollRuntime：Alpine aarch64，支持管道/&&/重定向）。
        env["TMPDIR"] = NSTemporaryDirectory()
        env["LANG"] = "en_US.UTF-8"
        env["TERM"] = "dumb"
        // v7.1.290：有 API Key 就同时给环境变量（部分 codex 版本只读 env，不读 auth.json）
        if let key = CodexKernel.apiKey {
            env["OPENAI_API_KEY"] = key
        }
        wire()
        try rpc.start(binary: binary, environment: env)
        NetworkLog.shared.log("[codex] app-server started: \(binary)")
    }

    /// `thread/start`：一次请求，不做参数降级。
    /// dynamicTools 由 initialize 的 capabilities.experimentalApi 授权；被拒就明确报错。
    private func startThread(instructions: String?, completion: @escaping (Result<String, Error>) -> Void) {
        let specs = CodexEngine.dynamicToolSpecs()
        var params: [String: Any] = ["cwd": CodexKernel.workspacePath]
        if !specs.isEmpty { params["dynamicTools"] = specs }
        // 系统提示词走 developerInstructions，**不覆盖 baseInstructions**：
        // codex 自带的基础提示词定义了它的工作方式（计划、前言消息、AGENTS.md 规则、补丁流程），
        // 覆盖掉会让模型失去这些行为。MT-Agent 专门内置一份 codex-fallback-prompt.md 就是这个原因。
        if let trimmed = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            params["developerInstructions"] = trimmed
        }
        // 模型同样来自 设置 → 模型（与 config.toml 的 model_provider 配套）
        if let cfg = CodexKernel.activeConfig, !cfg.model.isEmpty {
            params["model"] = cfg.model
            params["modelProvider"] = "trollagent"
        }

        rpc.request("thread/start", params: params) { result in
            switch result {
            case .failure(let error):
                completion(.failure(CodexRPCError(code: (error as? CodexRPCError)?.code ?? -1,
                                                  message: "创建会话失败：\(error.localizedDescription)")))
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
    }

    static func isParamRejection(_ error: Error) -> Bool {
        guard let e = error as? CodexRPCError else { return false }
        return e.code == -32602 || e.code == -32600 || e.message.lowercased().contains("unknown")
            || e.message.lowercased().contains("invalid")
    }

    /// data:image/...;base64 落成 $TMPDIR 里的真实文件，供 codex 的 localImage 读取
    static func materialize(dataURL: String) -> String? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let header = String(dataURL[dataURL.startIndex..<comma])
        let payload = String(dataURL[dataURL.index(after: comma)...])
        guard header.contains("base64"), let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
            return nil
        }
        let ext: String
        if header.contains("image/png") { ext = "png" }
        else if header.contains("image/heic") { ext = "heic" }
        else if header.contains("image/webp") { ext = "webp" }
        else { ext = "jpg" }

        let dir = NSTemporaryDirectory() + "codex-images"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/img-\(UUID().uuidString).\(ext)"
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return path
        } catch {
            NetworkLog.shared.log("[codex] 图片落盘失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func startTurn(_ turn: CodexTurn, threadId: String) {
        turn.onStatus?("思考中…")
        var input: [[String: Any]] = []
        // 附件图片：data URL 落成临时文件后走官方 localImage
        // （image.url 要求可访问的 URL，data: 形式不被接受）
        for image in turn.images.prefix(4) {
            if image.hasPrefix("data:"), let path = CodexRuntime.materialize(dataURL: image) {
                input.append(["type": "localImage", "path": path])
            } else {
                input.append(["type": "image", "url": image])
            }
        }
        input.append(["type": "text", "text": turn.prompt, "text_elements": []])

        var params: [String: Any] = ["threadId": threadId, "input": input]
        // 每轮带上当前选中的模型：设置里换模型后不必重建 thread，下一轮即生效
        if let cfg = CodexKernel.activeConfig, !cfg.model.isEmpty { params["model"] = cfg.model }
        turn.startedAt = Date()
        turn.lastActivityAt = Date()

        rpc.request("turn/start", params: params) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.finish(turn, .failure(CodexRPCError(code: (error as? CodexRPCError)?.code ?? -1,
                                                         message: "发送失败：\(error.localizedDescription)")))
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
            // 兜底：某些版本不发 agentMessage/delta，只在 item/completed 里给全文
            if method == "item/completed", (item["type"] as? String) == "agentMessage" {
                let full = (item["text"] as? String) ?? ""
                if !full.isEmpty && turn.text.isEmpty {
                    turn.text = full
                    DispatchQueue.main.async { turn.onDelta?(full) }
                }
            }
            emitCard(for: item, completed: method == "item/completed", turn: turn)

        case "thread/tokenUsage/updated", "token_count":
            turn.usage = Self.extractUsage(params) ?? turn.usage

        case "turn/completed":
            if turn.usage == nil { turn.usage = Self.extractUsage(params) }
            let thinking = turn.thinking.isEmpty ? nil : turn.thinking
            finish(turn, .success((text: turn.text, thinking: thinking)))

        case "error":
            // 官方 ErrorNotification: { error: {message, codexErrorInfo, additionalDetails}, willRetry, threadId, turnId }
            let payload = params["error"] as? [String: Any]
            let rawMessage = (payload?["message"] as? String)
                ?? (params["message"] as? String)
                ?? "Codex 返回错误"
            let hint = Self.hint(for: payload?["codexErrorInfo"])
            let extra = (payload?["additionalDetails"] as? String)
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let composed = ([rawMessage, hint, extra].compactMap { $0 }).joined(separator: " · ")
            let willRetry = (params["willRetry"] as? Bool) ?? false

            if willRetry {
                // 服务端自己在重试，别把这一轮判死
                turn.lastActivityAt = Date()
                DispatchQueue.main.async { turn.onStatus?("⚠️ \(composed)（codex 重试中）") }
                return
            }
            NetworkLog.shared.log("[codex] error: \(composed)")
            finish(turn, .failure(CodexRPCError(code: -7, message: composed)))

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
        case "userMessage", "agentMessage", "plan", "todoList", "warning", "error":
            // 这些是对话内容本身（用户消息 / 助手消息 / 计划），不是工具调用。
            // 旧实现落到 default 分支，于是聊天里冒出一堆名叫 "userMessage"/"agentMessage" 的"工具卡"。
            return
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
            return ["decision": CodexApprovalDecision.decline.rawValue]
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

    /// 把 codexErrorInfo 翻译成用户能动手的一句话。
    /// 官方取值：unauthorized / rateLimitExceeded / usageLimitExceeded / contextWindowExceeded /
    ///          httpConnectionFailed / serverOverloaded / badRequest / sandboxError / other …
    static func hint(for info: Any?) -> String? {
        guard let info else { return nil }
        var key = ""
        var httpStatus: Int?

        if let s = info as? String {
            key = s
        } else if let dict = info as? [String: Any], let first = dict.first {
            key = first.key
            if let inner = first.value as? [String: Any], let code = inner["httpStatusCode"] {
                httpStatus = code as? Int
            }
        }
        guard !key.isEmpty else { return nil }

        var text: String
        switch key {
        case "unauthorized":
            text = "未登录或登录态失效：去设置 →「Codex 内核」配置 API Key / auth.json"
        case "rateLimitExceeded":
            text = "被限流，稍等再试"
        case "usageLimitExceeded":
            text = "用量额度已用尽"
        case "contextWindowExceeded":
            text = "上下文超限，建议新建会话"
        case "httpConnectionFailed", "responseStreamConnectionFailed", "responseStreamDisconnected":
            text = "网络连接失败"
        case "serverOverloaded":
            text = "服务端繁忙"
        case "badRequest":
            text = "请求被拒（参数或模型不支持）"
        case "sandboxError":
            text = "沙箱错误（iOS 上无系统沙箱，通常是命令被执行环境拒绝）"
        default:
            text = "错误类型 \(key)"
        }
        if let code = httpStatus { text += "（HTTP \(code)）" }
        return text
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

        // turn 结束立刻释放后台额度（turn 期间由 submit 持有）
        BackgroundKeeper.shared.end()

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
