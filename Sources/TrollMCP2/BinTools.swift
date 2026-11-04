import Foundation
import UIKit

/// 包内原生工具（`$APP/bin` 里的真二进制）直接暴露成 MCP 工具，名字 `bin.<cmd>`。
///
/// 为什么需要：iOS 上没有 `/bin/sh`，codex 内置的 shell 工具起不了子进程；
/// 但 `posix_spawn` 可以直接执行这些 arm64 二进制。于是把常用分析工具单独注册出来，
/// codex 就能不经 shell 用 `jq` 解析 JSON、用 `objdump`/`r2`/`strings` 看 Mach-O。
///
/// 不暴露改包类工具（ldid / optool / insert_dylib / ct_bypass）——那是破坏性的，不该由模型随手调。
enum BinTools {
    /// 白名单：只读分析向 + 解释器
    static let allowlist: [String] = [
        "jq", "tree", "xz", "which",
        "r2", "cstool", "objdump", "nm", "readelf", "size", "strings", "jtool2",
        "python3", "node", "lua"
    ]

    static var directory: String { Bundle.main.bundlePath + "/bin" }

    static func available() -> [String] {
        let fm = FileManager.default
        return allowlist.filter { fm.isExecutableFile(atPath: directory + "/" + $0) }
    }

    /// 在 registerBuiltinTools 末尾调用
    static func registerAll() {
        let names = available()
        guard !names.isEmpty else { return }
        let registry = ToolRegistry.shared
        for name in names {
            let tool = BinMCPTool(command: name, path: directory + "/" + name)
            if registry.definitions.contains(where: { $0.name == tool.definition.name }) { continue }
            registry.register(tool)
        }
        AuditLog.shared.log("core", detail: "bin.* tools: \(names.joined(separator: ","))")
    }

    /// 把 "a b \"c d\"" 拆成参数数组（支持单/双引号，反斜杠转义）
    static func split(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                continue
            }
            if ch == " " || ch == "\t" {
                if !current.isEmpty { out.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// 一个 `bin.<cmd>` 工具
final class BinMCPTool: MCPTool {
    let definition: ToolDefinition
    private let path: String

    init(command: String, path: String) {
        self.path = path
        definition = ToolDefinition(
            name: "bin.\(command)",
            summary: "直接运行包内原生 \(command)（iOS arm64 二进制，不经 shell）。"
                + "用于 jq 解析 JSON / objdump、nm、strings、r2 分析 Mach-O / python3、node 跑脚本。"
                + "参数里的路径请写绝对路径（进程没有工作目录概念）。",
            parameters: [
                "args": "命令行参数（空格分隔，含空格用引号包起来），必填",
                "timeout": "超时秒数（默认 60）"
            ],
            returns: [
                "stdout": "标准输出（超过 4MB 截断）",
                "stderr": "标准错误",
                "exit": "退出码（0=成功）"
            ],
            verified: false,
            category: "analysis",
            uiSummary: "运行 \(command)"
        )
    }

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw MCPError.invalidParams("bin/\(definition.name) 不存在或不可执行")
        }
        let line = (params["args"] as? String) ?? ""
        let args = BinTools.split(line)
        let timeout = Double((params["timeout"] as? String) ?? "") ?? 60

        // 注意：不能传 workingDir —— BuildRunner 在有 cwd 时会包一层 /bin/sh，而 iOS 没有 sh
        let result = BuildRunner.shared.run(executable: path, args: args, workingDir: nil, timeout: timeout)

        var out: [String: Any] = [
            "exit": Int(result.exitCode),
            "stdout": result.stdout,
            "stderr": result.stderr
        ]
        if let spawnError = result.spawnError { out["spawnError"] = spawnError }
        if result.timedOut { out["timedOut"] = true }
        return out
    }
}
