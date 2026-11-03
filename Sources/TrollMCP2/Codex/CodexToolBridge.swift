import Foundation

/// 工具暴露层——**唯一真源**。
///
/// 为什么要单独抽出来：内核有两条通往工具的路
///   1) `dynamicTools`：codex 通过 `item/tool/call` 回调 App 进程内执行（默认通道）
///   2) MCP stdio：`TrollAgent --codex-mcp`，给外部客户端（VS Code / Obsidian）复用
///
/// 继承下来的实现是两边各写一份，结果三件事全不一致：
///   · 白名单过滤：dynamic 侧过滤了 `subagent.*`，MCP 侧没过滤 → 同一个 App 两条通道工具集不同
///   · 参数类型推断：两套启发式（一套看中文关键词、一套看英文），同一个工具两边 schema 不同
///   · 名字清洗：只有一边处理了撞名（`a.b` 与 `a_b` 都会变成 `a_b`，映射回来会指错工具）
///
/// 现在统一在这里算，两边都只是消费者。
enum CodexToolBridge {

    // MARK: 暴露范围

    /// 默认只暴露"Codex 内置工具做不到"的设备能力；文件/命令/搜索交给 codex 自己
    static var defaultToolNames: [String] { [
        "device.info", "device.snapshot", "device.refresh_container",
        "app.status", "app.launch", "app.stop", "app.install", "app.uninstall",
        "control.screenshot", "control.tap_text", "control.tap_selector",
        "control.type_text", "control.find",
        "browser.navigate", "browser.snapshot", "browser.text", "browser.click",
        "injection.list", "injection.status", "injection.enable", "injection.disable",
        "ipa.inspect", "app.decrypt", "app.entitlements",
        "ocr.image", "reminder", "location.get",
        "shell.exec"   // codex 自带 shell 在 iOS 沙盒里不一定可用，先留着兜底
    ] }

    /// `Documents/trollcodex-tools.txt`：文件不存在=默认表；空文件/全注释=全部工具
    static var allowlist: [String]? {
        let path = NSHomeDirectory() + "/Documents/trollcodex-tools.txt"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return defaultToolNames
        }
        let lines = raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return lines.isEmpty ? nil : lines
    }

    /// 两条通道共用的暴露集合：先按白名单，再去掉已并入 codex 的子代理工具
    static func exposedDefinitions() -> [ToolDefinition] {
        let allow = allowlist.map(Set.init)
        return ToolRegistry.shared.enabledDefinitions.filter { def in
            if def.name.lowercased().hasPrefix("subagent") { return false }
            guard let allow else { return true }
            return allow.contains(def.name)
        }
    }

    // MARK: 命名（清洗 + 反向映射，防撞名）

    /// 只保留 [A-Za-z0-9_-]（MCP 与 dynamicTools 都要求）
    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    /// 生成 "对外的唯一名 → 原始工具名" 映射。
    /// 撞名（`a.b` 与 `a_b`）时给后者加序号，保证映射一一对应。
    static func nameMap(for definitions: [ToolDefinition]) -> [String: String] {
        var map: [String: String] = [:]
        for def in definitions {
            var api = sanitize(def.name)
            if map[api] != nil {
                var index = 2
                while map["\(api)_\(index)"] != nil { index += 1 }
                api = "\(api)_\(index)"
            }
            map[api] = def.name
        }
        return map
    }

    static func original(for sanitized: String, map: [String: String]) -> String {
        map[sanitized] ?? sanitized
    }

    // MARK: Schema

    /// 参数类型：按参数名/说明做保守推断（不再一律 string）
    static func jsonType(name: String, desc: String) -> String {
        let key = name.lowercased()
        let text = desc.lowercased()
        if text.contains("true/false") || text.contains("布尔") || key.hasPrefix("is_") || key.hasPrefix("enable") {
            return "boolean"
        }
        if text.contains("数组") || text.contains("列表") || text.contains("array") {
            return "array"
        }
        let numeric = ["count", "limit", "timeout", "pid", "port", "seconds", "lines",
                       "depth", "size", "index", "duration", "level", "num"]
        if numeric.contains(where: { key.contains($0) }) { return "number" }
        return "string"
    }

    static func isRequired(_ desc: String) -> Bool {
        let lower = desc.lowercased()
        return desc.contains("必填") || lower.contains("required")
    }

    /// 统一的 inputSchema（JSON Schema 子集）
    static func inputSchema(params: [String: String]) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        for (key, desc) in params {
            properties[key] = ["type": jsonType(name: key, desc: desc), "description": desc]
            if isRequired(desc) { required.append(key) }
        }
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required.sorted() }
        return schema
    }

    /// dynamicTools 用的 function spec
    static func functionSpecs() -> (specs: [[String: Any]], map: [String: String]) {
        let defs = exposedDefinitions()
        let map = nameMap(for: defs)
        var specs: [[String: Any]] = []
        // 按 map 反查，保证名字与 map 完全一致（撞名时后缀也对得上）
        for (api, originalName) in map.sorted(by: { $0.value < $1.value }) {
            guard let def = defs.first(where: { $0.name == originalName }) else { continue }
            specs.append([
                "type": "function",
                "name": api,
                "description": def.summary,
                "inputSchema": inputSchema(params: def.parameters)
            ])
        }
        return (specs, map)
    }
}
