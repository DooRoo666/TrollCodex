import Foundation

/// 把工具注册表暴露成一个 stdio MCP server（给外部客户端用：VS Code / Obsidian / 自己的脚本）。
///
/// 启动：`TrollAgent --codex-mcp`
/// 客户端配置（`$CODEX_HOME/config.toml`）：
///     [mcp_servers.trollagent]
///     command = "/var/containers/Bundle/Application/.../TrollAgent.app/TrollAgent"
///     args = ["--codex-mcp"]
///
/// 注意：App 内部对话**不走这条**——codex 起进程内 dynamicTools 直连（少一个进程、少一串失败点）。
/// 这条只为"外部客户端复用同一批工具"，默认关闭，由 `Documents/trollcodex-mcp.txt` 决定是否注册。
///
/// 工具集合/命名/schema 全部来自 `CodexToolBridge`，和 App 内通道严格一致。
enum CodexMCPServer {
    static let protocolVersion = "2025-06-18"

    static func run() -> Never {
        log("trollcodex-mcp ready (pid \(ProcessInfo.processInfo.processIdentifier))")
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
}

// MARK: - 协议分发

private extension CodexMCPServer {
    static func handle(_ msg: [String: Any]) {
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            reply(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "trollagent", "version": appVersion]
            ])

        case "notifications/initialized", "notifications/cancelled":
            break

        case "ping":
            reply(id: id, result: [:])

        case "tools/list":
            reply(id: id, result: ["tools": toolList()])

        case "tools/call":
            guard let name = params["name"] as? String else {
                reply(id: id, errorCode: -32602, message: "missing tool name")
                return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            reply(id: id, result: call(name: name, arguments: arguments))

        default:
            if id != nil { reply(id: id, errorCode: -32601, message: "method not found: \(method)") }
        }
    }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    static func toolList() -> [[String: Any]] {
        let defs = CodexToolBridge.exposedDefinitions()
        let map = CodexToolBridge.nameMap(for: defs)
        return map.sorted { $0.key < $1.key }.compactMap { api, originalName in
            guard let def = defs.first(where: { $0.name == originalName }) else { return nil }
            return [
                "name": api,
                "description": def.summary,
                "inputSchema": CodexToolBridge.inputSchema(params: def.parameters)
            ]
        }
    }

    static func call(name: String, arguments: [String: Any]) -> [String: Any] {
        let defs = CodexToolBridge.exposedDefinitions()
        let map = CodexToolBridge.nameMap(for: defs)
        let original = CodexToolBridge.original(for: name, map: map)
        do {
            let result = try ToolRegistry.shared.dispatch(name: original, params: arguments)
            return ["content": [["type": "text", "text": jsonString(result)]], "isError": false]
        } catch {
            return ["content": [["type": "text", "text": "ERROR: \(error.localizedDescription)"]], "isError": true]
        }
    }

    static func jsonString(_ object: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: object)
    }

    static func reply(id: Any?, result: [String: Any]) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func reply(id: Any?, errorCode: Int, message: String) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "error": ["code": errorCode, "message": message]])
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
