import Foundation

/// 附属能力（上下文压缩、后台任务、摘要）的一次性 Codex 调用。
///
/// 全 App 只有 Codex 一条模型通道，不再回退 OpenAI。
/// 这里复用常驻运行时（不再为一次摘要另起一个 codex 进程）：
///   · 写完就丢 thread（`CodexThreadStore.remove`），不会在 codex 里堆垃圾会话
///   · 审批一律拒绝（摘要任务不需要写文件、也不需要弹框打扰用户）
final class CodexOneShot {
    typealias Completion = (Result<String, Error>) -> Void

    private static let queue = DispatchQueue(label: "trollcodex.oneshot")

    static func complete(prompt: String,
                         timeout: TimeInterval = 240,
                         onDelta: ((String) -> Void)? = nil,
                         completion: @escaping Completion) {
        let key = "oneshot-" + UUID().uuidString
        let config = ModelStore.shared.selected

        // 单轮串行：主对话在跑时会话被拒绝，这里给一个短失败（调用方本来就有兜底）
        _ = CodexRuntime.shared.submit(
            conversationKey: key,
            prompt: prompt,
            instructions: nil,
            config: config,
            approvalMode: .denyAll,
            onStatus: nil,
            onDelta: onDelta,
            onThinking: nil,
            onToolCard: nil,
            completion: { result in
                CodexThreadStore.shared.remove(key)
                switch result {
                case .success(let payload):
                    completion(.success(payload.text))
                case .failure(let error):
                    completion(.failure(error))
                }
            })
    }
}
