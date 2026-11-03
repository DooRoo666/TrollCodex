import SwiftUI

/// Codex 内核页——**只放没别处可放的东西**。
///
/// 模型与密钥统一在「设置 → 模型」，运行时就内置在包里（`CodexRuntime/codex`），
/// 所以这里不再提供任何"模型配置 / 登录配置 / 安装运行时"的入口，只保留三块：
///   1) 只读状态：当前模型来源、运行时是否就绪（一行，供排查）
///   2) 审批策略：codex 要跑命令/改文件时怎么处理（ask / auto / deny）
///   3) 上下文：已持久化的会话 thread 数 + 一键清空（换模型/换上游后建议清一次）
struct CodexRuntimeStatusView: View {
    @State private var binaryPath: String? = CodexKernel.binaryPath
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
            Section {
                row("模型", CodexKernel.modelDescription)
                row("密钥", CodexKernel.activeConfig?.apiKey.isEmpty == false ? "已配置" : "未配置",
                    color: CodexKernel.activeConfig?.apiKey.isEmpty == false ? .green : .orange)
                row("运行时", binaryPath == nil ? "缺失（包内未带）" : "已就绪",
                    color: binaryPath == nil ? .orange : .green)
                row("进程", processAlive ? "运行中" : "未启动")
            } header: {
                Text("状态")
            } footer: {
                Text("模型与密钥统一在「设置 → 模型」里改，本页只读。")
                    .font(.footnote)
            }

            Section {
                Picker("策略", selection: $policy) {
                    ForEach(Self.policies) { item in
                        Text(item.label).tag(item.id)
                    }
                }
                .pickerStyle(.inline)
                .onChange(of: policy) { value in
                    UserDefaults.standard.set(value, forKey: "trollcodex.approval.policy")
                }
            } header: {
                Text("审批")
            } footer: {
                Text("codex 要跑命令 / 改文件时按此处理。「本会话内全部允许」只在本次启动有效。")
                    .font(.footnote)
            }

            Section {
                row("已持久化会话", "\(threadKeys.count) 个")
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("清空会话上下文", systemImage: "trash")
                }
                .disabled(threadKeys.isEmpty)
            } header: {
                Text("上下文")
            } footer: {
                Text("换模型或换上游（baseURL）后建议清一次：codex 的 thread 绑定创建时的 provider。")
                    .font(.footnote)
            }
        }
        .navigationTitle("Codex 内核")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .alert(isPresented: $showResetConfirm) {
            Alert(title: Text("清空会话上下文？"),
                  message: Text("所有会话的 codex thread 会被丢弃，下一轮重新建立（本地聊天历史仍在，会自动重放最近几轮）。"),
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
        processAlive = CodexRuntime.shared.isProcessAlive
        threadKeys = CodexThreadStore.shared.debugKeys()
        policy = CodexApprovalCenter.shared.policy.rawValue
    }
}
