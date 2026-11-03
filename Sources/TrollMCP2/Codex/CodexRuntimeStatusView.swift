import SwiftUI

/// Codex 内核状态页（设置 → Codex 内核）。
///
/// 存在的意义：旧版内核换了，但**没有任何入口告诉用户"运行时在哪、有没有装上、上下文存在哪"**，
/// 出问题只能靠猜。这里把三件事摊开：
///   · 运行时：二进制路径 / CODEX_HOME / 进程是否活着
///   · 上下文：已持久化多少个会话 thread（可一键清空重开）
///   · 审批：ask（默认弹框）/ auto（全放行）/ deny（只读）—落盘持久生效
struct CodexRuntimeStatusView: View {
    @State private var binaryPath: String? = CodexKernel.binaryPath
    @State private var homePath: String = CodexKernel.homePath
    @State private var processAlive: Bool = CodexRuntime.shared.isProcessAlive
    @State private var threadKeys: [String] = []
    @State private var policy: String = CodexApprovalCenter.shared.policy.rawValue
    @State private var showResetConfirm = false

    private struct PolicyOption: Identifiable {
        let id: String
        let label: String
    }

    private static let policies: [PolicyOption] = [
        PolicyOption(id: "ask", label: "逐次确认（推荐）"),
        PolicyOption(id: "auto", label: "全部放行"),
        PolicyOption(id: "deny", label: "全部拒绝（只读）")
    ]

    var body: some View {
        List {
            Section(header: Text("运行时")) {
                row("二进制", binaryPath == nil ? "未找到" : "已就绪",
                    color: binaryPath == nil ? .orange : .green)
                row("登录态", CodexKernel.authStatusDescription,
                    color: CodexKernel.authStatusDescription.hasPrefix("已就绪") ? .green : .orange)
                row("模型", CodexKernel.modelDescription,
                    color: CodexKernel.activeConfig == nil ? .orange : .primary)
                row("进程", processAlive ? "运行中" : "未启动（发第一条消息时启动）",
                    color: processAlive ? .green : .secondary)
                if let p = binaryPath {
                    row("路径", p)
                }
                row("CODEX_HOME", homePath)
                Button {
                    refresh()
                } label: {
                    Label("重新检测", systemImage: "arrow.clockwise")
                }
            }

            if binaryPath == nil || !CodexKernel.authStatusDescription.hasPrefix("已就绪") {
                Section(header: Text("怎么补齐")) {
                    Text("运行时：本包已内置（CodexRuntime/codex）。若显示「未找到」，说明内置产物没生成——把 iOS 版 codex 放到 Documents/codex/codex（chmod 755）即可。")
                        .font(.footnote)
                    Text("登录态（二选一）：")
                        .font(.footnote)
                    Text("① Documents/codex-apikey.txt 里写一行 sk-... 的 API Key；")
                        .font(.footnote)
                    Text("② 把电脑 / NanoCode 的 auth.json 改名为 Documents/codex-auth.json 放进来。")
                        .font(.footnote)
                    Text("放好后回本页点「重新检测」，再发一条消息。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("上下文（thread）")) {
                row("已持久化会话", "\(threadKeys.count) 个")
                if !threadKeys.isEmpty {
                    ForEach(threadKeys.prefix(8), id: \.self) { key in
                        Text(key)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("清空所有会话上下文", systemImage: "trash")
                }
                .disabled(threadKeys.isEmpty)
            }

            Section(header: Text("审批策略")) {
                Picker("策略", selection: $policy) {
                    ForEach(Self.policies) { item in
                        Text(item.label).tag(item.id)
                    }
                }
                .pickerStyle(.inline)
                .onChange(of: policy) { value in
                    UserDefaults.standard.set(value, forKey: "trollcodex.approval.policy")
                }
                Text("Codex 要跑命令 / 改文件时会按此策略处理。「本会话内全部允许」只在当前这次启动有效。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                Text("会话 thread 存在 Documents/trollcodex-threads.json；删掉它等价于「全部重开」。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Codex 内核")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .alert(isPresented: $showResetConfirm) {
            Alert(title: Text("清空会话上下文？"),
                  message: Text("所有会话的 codex thread 会被丢弃，下一轮将重新建立上下文（历史仍保存在本地会话里，会自动重放最近几轮）。"),
                  primaryButton: .destructive(Text("清空")) {
                      CodexThreadStore.shared.reset()
                      refresh()
                  },
                  secondaryButton: .cancel())
        }
    }

    private func row(_ title: String, _ value: String, color: Color = .secondary) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(color)
                .multilineTextAlignment(.trailing)
                .font(.footnote)
        }
    }

    private func refresh() {
        binaryPath = CodexKernel.binaryPath
        homePath = CodexKernel.homePath
        processAlive = CodexRuntime.shared.isProcessAlive
        threadKeys = CodexThreadStore.shared.debugKeys()
        policy = CodexApprovalCenter.shared.policy.rawValue
    }
}
