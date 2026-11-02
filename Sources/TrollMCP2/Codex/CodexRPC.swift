import Foundation

struct CodexRPCError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { "Codex RPC \(code): \(message)" }
}

/// Codex app-server 的 JSON-RPC 客户端。
/// 传输是换行分隔的 JSON（已在 0.162.1 上实测确认），不是 Content-Length 帧。
final class CodexRPC {
    private let process = CodexProcess()
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]

    private(set) var isRunning = false

    /// 服务端通知（item/started、turn/completed 等）
    var onNotification: ((String, [String: Any]) -> Void)?
    /// 服务端反向请求（审批等），返回值作为 result 直接回给 Codex
    var onServerRequest: ((Int, String, [String: Any]) -> [String: Any]?)?
    /// stderr / 进程退出
    var onLog: ((String) -> Void)?

    func start(binary: String, arguments: [String] = ["app-server"], environment: [String: String]) throws {
        process.onLine = { [weak self] line in self?.handle(line: line) }
        process.onExit = { [weak self] code in
            self?.isRunning = false
            self?.onLog?("codex 进程退出: \(code)")
        }
        try process.start(binary: binary, arguments: arguments, environment: environment)
        isRunning = true
    }

    func stop() {
        flushPending(error: CodexRPCError(code: -1, message: "连接已关闭"))
        process.terminate()
        isRunning = false
    }

    func request(_ method: String, params: [String: Any] = [:], completion: ((Result<Any, Error>) -> Void)? = nil) {
        let id: Int
        lock.lock()
        id = nextID
        nextID += 1
        if let completion { pending[id] = completion }
        lock.unlock()

        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        process.write(line: text)
    }

    func notify(_ method: String, params: [String: Any] = [:]) {
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        process.write(line: text)
    }

    func reply(id: Int, result: [String: Any]) {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        process.write(line: text)
    }

    // MARK: - 内部

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            onLog?("无法解析: \(line.prefix(200))")
            return
        }

        // 响应
        if let idValue = obj["id"], let id = idValue as? Int, (obj["result"] != nil || obj["error"] != nil) {
            lock.lock()
            let cb = pending.removeValue(forKey: id)
            lock.unlock()
            if let error = obj["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? -1
                let message = error["message"] as? String ?? "unknown"
                cb?(.failure(CodexRPCError(code: code, message: message)))
            } else {
                cb?(.success(obj["result"] ?? [:]))
            }
            return
        }

        guard let method = obj["method"] as? String else { return }
        let params = obj["params"] as? [String: Any] ?? [:]

        // 服务端反向请求（带 id）
        if let idValue = obj["id"], let id = idValue as? Int {
            // 返回 nil 表示"由调用方异步回包"（例如动态工具要跑完再回）
            if let handler = onServerRequest, let result = handler(id, method, params) {
                reply(id: id, result: result)
            }
            return
        }

        onNotification?(method, params)
    }

    private func flushPending(error: Error) {
        lock.lock()
        let callbacks = pending
        pending.removeAll()
        lock.unlock()
        callbacks.values.forEach { $0(.failure(error)) }
    }
}
