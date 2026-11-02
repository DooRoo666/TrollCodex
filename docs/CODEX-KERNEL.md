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
CodexKernel.isEnabled = true     // 恒为 true（Codex 是唯一内核，没有 OpenAI 回退）
```

关闭分支已不存在；设备上没有 codex 运行时，对话会直接报错并给出安装指引。

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

1. ~~审批：`item/commandExecution/requestApproval` 等目前默认放行，需接 UI 弹窗~~ → **已做**，见下节
2. ~~工具卡：把 `item/started|completed` 映射到现有 `AssistantBlock` 卡片~~ → **已做**（`applyCodexToolCard`）
3. ~~多会话：`threadID` 按会话持久化，避免重启后重开线程~~ → **已做**（`CodexThreadStore`）
4. 图片/大结果：MCP 只能回文本，截图落盘回路径 → 图片项已接（`Documents/trollcodex-images.txt` 开关，默认关）
5. ~~`send` 的 `messages` 目前只取最后一条 user，历史交给 Codex 的 thread 状态~~ → **已做**（新 thread 自动重放最近 24 条）

## 2026-11-02 升级：上下文与稳定性（P0 落地）

上一版的根因不是协议，而是**生命周期**：`Models` 每个请求 `CodexEngine(config:)` 新实例 →
新 `CodexRPC` → 新进程 → 新 thread，于是每轮 1~3s 冷启动、上下文每轮清零（`send` 只送最后一条 user，
thread 又是新的）。工具、UI 都看不出问题，但"记不住上文"是必然的。

现在拆成三层：

| 层 | 文件 | 职责 |
|---|---|---|
| 进程/线程 | `Codex/CodexRuntime.swift` | 常驻一个 `codex app-server`；thread 按会话键复用并落盘 `Documents/trollcodex-threads.json`；单 turn 串行；看门狗 30 分钟；进程死了下一轮自动重建 |
| 协议翻译 | `Codex/CodexEngine.swift` | 把 `messages` 拼成一轮 prompt（system 消息 → `baseInstructions`，不支持则降级）、tool 事件 → `CodexToolCard`、usage → `UsageRecorder` |
| 审批 | `Codex/CodexApproval.swift` | 真弹框（`ask`/`auto`/`deny`，`Documents/trollcodex-approval.txt` 或设置页切换），带"本会话内全部允许" |

配套：

- `Codex/CodexRuntimeStatusView.swift` + 设置页入口：运行时路径、进程状态、已持久化会话数、清空上下文
- `CodexProcess`：读线程只持自己的 fd（旧版 `terminate()` 会从另一个线程 close 正在读的 fd）、退出码改用 `waitpid` 真值
- `dynamicTools` 参数类型不再一律 `string`；清洗名撞名自动加序号（`a.b` vs `a_b`）
- 一次性摘要（`CodexOneShot`）复用同一进程，审批一律拒绝，写完即丢 thread

### 仍然分属"第二条通道"（不是坏，是设计）

| 能力 | 通道 | 说明 |
|---|---|---|
| HUD 悬浮窗语音 | HTTP `chat/completions` | 独立进程，读 `trollmodel_configs.json` / App Group 配置；需要在模型页保留一份可用配置 |
| 后台代传（切后台继续跑） | — | `handoffActiveRequestToBackground` 仍直接 return：请求活在 codex 子进程里，系统不给代传 |
| 子代理 `subagent.*` | 原生 Codex 任务拆解 | 已从 `dynamicTools` 过滤（Codex 自己能拆任务）；`SubAgentTool` 仍走 `OpenAIClient`，无 key 时不可用 |



## 为什么不是只用 MCP

Codex 的 `thread/start` 支持 `dynamicTools`（`{type:"function",name,description,inputSchema}`），
模型调用时以 **服务端请求 `item/tool/call`** 回调客户端，客户端回
`{contentItems:[{type:"inputText",text}] | {type:"inputImage",imageUrl}, success:Bool}`。

对比 MCP：

| | 动态工具（默认） | MCP stdio |
|---|---|---|
| 进程 | App 进程内直接跑 | 另起一个自己的副本当 server |
| 传输 | JSON-RPC 同一连接 | stdin/stdout 子进程管道 |
| 工具结果 | 文本 **+ 图片** | 只能文本 |
| 失败点 | 少 | 路径/权限/启动顺序/超时 |

所以默认走 `dynamicTools`；`CodexMCPServer` 保留给外部 MCP 客户端（VS Code / Obsidian）复用同一批工具。


## 工具分层（默认策略）

| 层 | 通道 | 说明 |
|---|---|---|
| 文件读写、跑命令、打补丁、联网搜索 | Codex **内置工具** | 不注册，避免和 `shell_exec` / `read_file` 打架 |
| 手机独有能力（HID 注入、截图、装包、解密、HomeKit、定位、OCR…） | `dynamicTools` | 进程内回调，`item/tool/call` |
| 外部客户端复用（VS Code / Obsidian） | MCP stdio | 默认关，`Documents/trollcodex-mcp.txt` 存在才启用 |

### 白名单

`Documents/trollcodex-tools.txt`：

- 文件不存在 → 用代码里的默认表（约 28 个设备类工具）
- 空文件 / 全是注释 → 暴露全部工具
- 每行一个工具名（按 `ToolRegistry` 原名，如 `control.screenshot`），`#` 开头忽略

改完重启 App 生效，不用重编译。


## 唯一内核（2026-11-02 定稿）

- 主对话：`ModelStore` 里固定 `CodexEngine`，**没有任何 OpenAI 回退分支**
- 上下文压缩：`CodexOneShot.complete` —— 起一个独立 thread 跑摘要，不碰 OpenAI
- 子代理：`subagent*` 工具从 dynamicTools 里过滤掉（Codex 原生能拆解任务）
- `CodexKernel.isEnabled` 恒为 `true`
- `OpenAIClient` / `BackgroundLLM` / `SubAgentTool` 仍在工程里但已无调用路径，可后续删

若设备上没有 codex 运行时，对话会直接报错而不是悄悄切回 OpenAI。
