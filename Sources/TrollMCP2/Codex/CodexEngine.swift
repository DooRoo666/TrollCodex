import Foundation

/// Codex 内核适配层。
///
/// 分工（和上一版最大的区别）：
///   · 进程与 thread 的生命周期 → `CodexRuntime`（常驻，全 App 一份）
///   · 本类只做协议翻译：把 Models 的 `messages` 变成一轮 prompt，把事件变成 UI 回调
///
/// 旧版每个请求 `CodexEngine(config:)` 都新建 RPC + 新进程 + 新 thread，于是：
///   · 每轮 1~3s 冷启动
///   · 上下文每轮清零（`send` 只取最后一条 user 文本，thread 又是新的）
/// 现在这两件事都不存在了。
final class CodexEngine: ChatEngine {
    var onAuthCorrected: ((String) -> Void)?
    var currentReasoningLevel: Int = 0
    private(set) var isStreamingInFlight = false

    /// 会话标识：同一会话复用同一个 codex thread（上下文连续）
    var conversationKey: String = "default"

    /// 工具卡回调（显示用；工具已由 Codex 通过 dynamicTools 跑完，不要再执行）
    var onToolCard: ((CodexToolCard) -> Void)?

    private let config: ModelConfig
    private var handle: CodexTurnHandle?
    private var completion: ((Result<ChatResult, Error>) -> Void)?

    init(config: ModelConfig) {
        self.config = config
    }

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
        self.completion = completion

        // token 统计：begin 用真实 history 估输入（Codex 有真 usage 时会覆盖）
        UsageRecorder.shared.begin(messages: messages)

        let instructions = Self.systemPrompt(from: messages)
        let known = CodexThreadStore.shared.threadId(for: conversationKey) != nil
        let prompt = Self.buildPrompt(from: messages, replayHistory: !known)
        let images = messages.last(where: { $0.role == "user" })?.imageDataURLs ?? []

        let turn = CodexRuntime.shared.submit(
            conversationKey: conversationKey,
            prompt: prompt,
            instructions: instructions,
            images: images,
            config: config,
            onStatus: onStatus,
            onDelta: onDelta,
            onThinking: onThinking,
            onToolCard: { [weak self] card in
                self?.onToolCard?(card)
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.isStreamingInFlight = false
                self.handle = nil
                let cb = self.completion
                self.completion = nil
                switch result {
                case .success(let payload):
                    cb?(.success(.text(payload.text, thinking: payload.thinking)))
                case .failure(let error):
                    cb?(.failure(error))
                }
            })

        handle = turn
        if turn == nil {
            isStreamingInFlight = false
            self.completion = nil
        }
    }

    func cancel() {
        if let handle { CodexRuntime.shared.cancel(handle) }
        if isStreamingInFlight {
            isStreamingInFlight = false
            let cb = completion
            completion = nil
            cb?(.failure(CodexRPCError(code: -4, message: "已取消")))
        }
    }

    // MARK: - prompt 组装

    /// system 消息 = 系统提示词 / 开发者指令 / 工具目录 / 环境快照
    static func systemPrompt(from messages: [ChatMessage]) -> String? {
        let blocks = messages.filter { $0.role == "system" }
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !blocks.isEmpty else { return nil }
        return blocks.joined(separator: "\n\n")
    }

    static func lastUserText(in messages: [ChatMessage]) -> String {
        messages.last(where: { $0.role == "user" })?.content ?? ""
    }

    /// 新建 thread 时，把最近几轮压成一段文字一起带过去——
    /// 这样"换会话 / 清了 thread 缓存 / 首次升级"都不会把已有讨论丢失。
    static func buildPrompt(from messages: [ChatMessage], replayHistory: Bool) -> String {
        let userText = lastUserText(in: messages)
        guard replayHistory else { return userText }

        var lines: [String] = []
        for msg in messages.suffix(24) {
            switch msg.role {
            case "user":
                lines.append("User: " + trim(msg.content, 400))
            case "assistant":
                let text = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append("Assistant: " + trim(text, 400)) }
            case "tool":
                let name = msg.toolName ?? "tool"
                lines.append("Tool[\(name)]: " + trim(msg.content, 200))
            default:
                break
            }
        }
        // 最后一条 user 已经在正文里，避免重复
        if let last = lines.last, last.hasPrefix("User:"), last.contains(trim(userText, 400)) {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return userText }
        return """
        [This conversation has earlier turns. Continue it with the transcript below as context.]
        \(lines.joined(separator: "\n"))

        [Current user message]
        \(userText)
        """
    }

    private static func trim(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

// MARK: - 动态工具（进程内，不经 MCP/子进程）

extension CodexEngine {
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
        "shell.exec"   // Codex 自带 shell 在 iOS 沙盒里不一定可用，先留着兜底
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

    private static let specLock = NSLock()
    /// 清洗后的名字 → 原始工具名（防撞名：撞了就给后者加序号）
    private static var nameMap: [String: String] = [:]

    static func dynamicToolSpecs() -> [[String: Any]] {
        let allow = toolAllowlist.map(Set.init)
        let defs = ToolRegistry.shared.enabledDefinitions.filter { def in
            // 子代理已并入 Codex，不再作为独立工具暴露
            if def.name.lowercased().hasPrefix("subagent") { return false }
            guard let allow else { return true }
            return allow.contains(def.name)
        }

        specLock.lock()
        nameMap.removeAll()
        var specs: [[String: Any]] = []
        for def in defs {
            var api = sanitize(def.name)
            if nameMap[api] != nil {
                var index = 2
                while nameMap["\(api)_\(index)"] != nil { index += 1 }
                api = "\(api)_\(index)"
            }
            nameMap[api] = def.name

            var props: [String: Any] = [:]
            for (key, desc) in def.parameters {
                props[key] = ["type": paramType(for: key, desc: desc), "description": desc]
            }
            specs.append([
                "type": "function",
                "name": api,
                "description": def.summary,
                "inputSchema": ["type": "object", "properties": props]
            ])
        }
        specLock.unlock()
        return specs
    }

    static func originalToolName(_ sanitized: String) -> String {
        specLock.lock()
        let hit = nameMap[sanitized]
        specLock.unlock()
        return hit ?? sanitized
    }

    /// 参数类型：不再一律 string（旧版全部当字符串，模型爱传错结构）
    static func paramType(for key: String, desc: String) -> String {
        let name = key.lowercased()
        let text = desc.lowercased()
        if text.contains("true/false") || text.contains("布尔") || name.hasPrefix("is_") || name.hasPrefix("enable") {
            return "boolean"
        }
        if text.contains("数组") || text.contains("列表") || text.contains("array") || name.hasSuffix("s") && text.contains("list of") {
            return "array"
        }
        let numeric = ["count", "limit", "timeout", "pid", "port", "seconds", "lines", "depth", "size", "index", "duration", "level"]
        if numeric.contains(where: { name.contains($0) }) { return "number" }
        if name.contains("path") || name.contains("url") || name.contains("id") || name.contains("name") { return "string" }
        return "string"
    }
}
