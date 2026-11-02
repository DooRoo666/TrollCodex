# Codex 内核接入（TrollCodex）

把 TrollAgent 的推理内核从「HTTP 调 OpenAI 兼容 API」换成**本机 Codex `app-server`**。
UI 不变，工具不变：Codex 通过 MCP 反向调用 TrollAgent 自己的 `ToolRegistry`。

## 数据流

```
用户输入
  └─ ChatEngine.send(...)            ← 原 OpenAIClient 的同签名协议
       └─ CodexEngine               ← 本仓库新增
            ├─ CodexRPC  ── stdio ── codex app-server（子进程，posix_spawn）
            │     ├─ 通知 item/agentMessage/delta      → onDelta（逐字流）
            │     ├─ 通知 item/reasoning/textDelta    → onThinking（思考块）
            │     └─ 通知 item/started|completed      → 工具卡状态
            └─ turn/start
                  └─ Codex 决定调工具
                        └─ MCP stdio → `TrollAgent --codex-mcp`
                              └─ ToolRegistry.shared.dispatch(name:params:)
                                    └─ 45 个原有工具，原样可跑
```

## 文件

| 文件 | 职责 |
|---|---|
| `CodexKernel.swift` | 开关（UserDefaults）、二进制路径发现、`ChatEngine` 协议 |
| `CodexProcess.swift` | `posix_spawn` + 管道 + 行读取（iOS 无 `Process`） |
| `CodexRPC.swift` | 行分隔 JSON-RPC 客户端（请求/通知/服务端请求） |
| `CodexEngine.swift` | 线程与回合管理、事件→UI 回调、取消 |
| `CodexMCPServer.swift` | `--codex-mcp` 模式：把 ToolRegistry 暴露成 MCP 工具 |

## 开关

```swift
CodexKernel.isEnabled = true     // 设置页可接一个 Toggle
```

关闭时完全走原来的 `OpenAIClient`，零行为变化。

## 运行前提

- 设备上要有 codex 运行时（NanoCodex 装过即可）：
  `.../Library/Application Support/NanoCodex/runtimes/codex/var/jb/usr/libexec/codex/codex`
- `CODEX_HOME` 必须是**可写目录**（实测 `/var/mobile/tmp` 可用，App 内用 Application Support）
- 首次运行前把 MCP server 写进 `$CODEX_HOME/config.toml`：

```toml
[mcp_servers.trollagent]
command = "/Applications/TrollAgent.app/TrollAgent"
args = ["--codex-mcp"]
```

## 实测记录（2026-11-02，本机）

- `codex app-server` 握手成功：`userAgent: probe/0.162.1 (iOS 16.1.0; ...)`
- 传输确认：**行分隔 JSON**（不是 Content-Length）
- `initialize` 最小参数即可；`thread/start` 全部字段可选
- `turn/start` 必填 `threadId` + `input: [{type:"text", text:...}]`

## 待办（P1）

1. 审批：`item/commandExecution/requestApproval` 等目前默认放行，需接 UI 弹窗
2. 工具卡：把 `item/started|completed` 映射到现有 `AssistantBlock` 卡片
3. 多会话：`threadID` 按会话持久化，避免重启后重开线程
4. 图片/大结果：MCP 只能回文本，截图落盘回路径
5. `send` 的 `messages` 目前只取最后一条 user，历史交给 Codex 的 thread 状态
