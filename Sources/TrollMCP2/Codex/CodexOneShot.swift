import Foundation

/// 附属能力（上下文压缩、后台任务、子代理）的一次性 Codex 调用。
/// 存在的意义：全 App 只保留 Codex 一条模型通道，不再回退 OpenAI。
final class CodexOneShot {
    typealias Completion = (Result<String, Error>) -> Void

    static func complete(prompt: String,
                         timeout: TimeInterval = 240,
                         onDelta: ((String) -> Void)? = nil,
                         completion: @escaping Completion) {
        Run(prompt: prompt, timeout: timeout, onDelta: onDelta, completion: completion).start()
    }

    private final class Run {
        private let rpc = CodexRPC()
        private let prompt: String
        private let timeout: TimeInterval
        private let onDelta: ((String) -> Void)?
        private let completion: Completion
        private var text = ""
        private var finished = false

        init(prompt: String, timeout: TimeInterval,
             onDelta: ((String) -> Void)?, completion: @escaping Completion) {
            self.prompt = prompt
            self.timeout = timeout
            self.onDelta = onDelta
            self.completion = completion
        }

        func start() {
            guard let binary = CodexKernel.binaryPath else {
                finish(.failure(CodexRPCError(code: -5, message: "未找到 codex 运行时，请在设置里安装")))
                return
            }
            CodexKernel.ensureConfig()

            var env = ProcessInfo.processInfo.environment
            env["CODEX_HOME"] = CodexKernel.homePath
            env["HOME"] = CodexKernel.homePath

            do {
                try rpc.start(binary: binary, environment: env)
            } catch {
                finish(.failure(error))
                return
            }

            rpc.onNotification = { [weak self] method, params in
                self?.handle(method, params)
            }
            // 一次性任务不需要写文件，所有审批一律拒绝
            rpc.onServerRequest = { _, _, _ in ["decision": "denied"] as [String: Any] }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(CodexRPCError(code: -6, message: "Codex 响应超时")))
            }

            rpc.request("thread/start", params: ["cwd": NSHomeDirectory()]) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.finish(.failure(error))
                case .success(let value):
                    let dict = value as? [String: Any] ?? [:]
                    let thread = dict["thread"] as? [String: Any]
                    guard let id = (thread?["id"] as? String) ?? (dict["threadId"] as? String) else {
                        self.finish(.failure(CodexRPCError(code: -3, message: "thread/start 未返回 id")))
                        return
                    }
                    self.startTurn(threadID: id)
                }
            }
        }

        private func startTurn(threadID: String) {
            let input: [[String: Any]] = [["type": "text", "text": prompt]]
            rpc.request("turn/start", params: ["threadId": threadID, "input": input]) { [weak self] result in
                if case .failure(let error) = result { self?.finish(.failure(error)) }
            }
        }

        private func handle(_ method: String, _ params: [String: Any]) {
            switch method {
            case "item/agentMessage/delta":
                if let delta = params["delta"] as? String {
                    text += delta
                    onDelta?(delta)
                }
            case "turn/completed":
                finish(.success(text))
            case "error":
                let message = (params["message"] as? String) ?? (params["error"] as? String) ?? "Codex 返回错误"
                finish(.failure(CodexRPCError(code: -7, message: message)))
            default:
                break
            }
        }

        private func finish(_ result: Result<String, Error>) {
            if finished { return }
            finished = true
            rpc.onNotification = nil
            rpc.onServerRequest = nil
            rpc.stop()
            DispatchQueue.main.async { [completion] in
                completion(result)
            }
        }
    }
}
