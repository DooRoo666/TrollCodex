import Foundation

/// 把 TrollAgent 的工具注册表暴露成一个 stdio MCP server。
/// 启动：`TrollAgent --codex-mcp`
/// Codex 侧配置（$CODEX_HOME/config.toml）：
/// [mcp_servers.trollagent]
/// command = "/var/containers/Bundle/Application/.../TrollAgent.app/TrollAgent"
/// args = ["--codex-mcp"]
enum CodexMCPServer {
    static let protocolVersion = "2025-06-18"

    static func run() -> Never {
        log("trollcodex-mcp ready")
        while let line = readLine(strippingNewline: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log("skip non-json line")
                continue
            }
            handle(msg)
        }
        exit(0)
    }

    private static func handle(_ msg: [String: Any]) {
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            reply(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "trollagent", "version": "7.1"]
            ])
        case "notifications/initialized", "notifications/cancelled":
            break
        case "ping":
            reply(id: id, result: [:])
        case "tools/list":
            reply(id: id, result: ["tools": toolList()])
        case "tools/call":
            guard let name = params["name"] as? String else {
                reply(id: id, error: [-32602, "missing tool name"])
                return
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            reply(id: id, result: call(name: name, arguments: args))
        default:
            if id != nil {
                reply(id: id, error: [-32601, "method not found: \(method)"])
            }
        }
    }
}

private extension CodexMCPServer {
    static func toolList() -> [[String: Any]] {
        ToolRegistry.shared.enabledDefinitions.map { def in
            [
                "name": mcpName(def.name),
                "description": def.summary,
                "inputSchema": schema(for: def.parameters)
            ]
        }
    }

    static func call(name: String, arguments: [String: Any]) -> [String: Any] {
        let original = originalName(name)
        do {
            let result = try ToolRegistry.shared.dispatch(name: original, params: arguments)
            return ["content": [["type": "text", "text": jsonString(result)]], "isError": false]
        } catch {
            return ["content": [["type": "text", "text": "ERROR: \(error.localizedDescription)"]], "isError": true]
        }
    }

    /// MCP 工具名只允许 [A-Za-z0-9_-]，TrollAgent 里有 shell.exec 这类点号名
    static func mcpName(_ raw: String) -> String {
        String(raw.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" { return ch }
            return "_"
        })
    }

    static func originalName(_ mcp: String) -> String {
        for def in ToolRegistry.shared.enabledDefinitions where mcpName(def.name) == mcp {
            return def.name
        }
        return mcp
    }

    static func schema(for params: [String: String]) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        for (key, desc) in params {
            properties[key] = ["type": jsonType(name: key, desc: desc), "description": desc]
            let lower = desc.lowercased()
            if desc.contains("必填") || lower.contains("required") { required.append(key) }
        }
        var result: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { result["required"] = required }
        return result
    }

    static func jsonType(name: String, desc: String) -> String {
        let lower = name.lowercased() + " " + desc.lowercased()
        if lower.contains("bool") || lower.contains("true/false") { return "boolean" }
        if lower.contains("数组") || lower.contains("array") || lower.contains("list of") { return "array" }
        if ["count", "limit", "timeout", "pid", "port", "seconds", "lines"].contains(where: { name.lowercased().contains($0) }) {
            return "number"
        }
        return "string"
    }

    static func jsonString(_ object: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: object)
    }

    static func reply(id: Any?, result: [String: Any]) {
        guard let id = id else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func reply(id: Any?, error: [Any]) {
        guard let id = id else { return }
        let code = error.count > 0 ? error[0] : -32603
        let message = error.count > 1 ? error[1] : "error"
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
