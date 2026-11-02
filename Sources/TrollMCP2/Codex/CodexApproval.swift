import Foundation
import UIKit

// MARK: - 审批（把"默认放行"换成真的问）
//
// Codex 在动手前会发反向请求：
//   item/commandExecution/requestApproval  → 要跑命令
//   item/fileChange/requestApproval        → 要改文件
// 旧实现统一回 approved（等于把确认环节关了）。这里改成弹框，且给"本次会话全部允许"的出口，
// 长任务不会被反复打断。
//
// 策略（不用改代码，落盘即可）：
//   Documents/trollcodex-approval.txt 内容写 auto  → 全部自动放行（旧行为）
//                                   写 deny  → 全部拒绝（只读模式）
//                                   写 ask / 文件不存在 → 弹框（默认）
// UserDefaults 键 trollcodex.approval.policy 同义，优先级更高。

struct CodexApprovalRequest {
    let method: String
    let payload: [String: Any]

    /// 给用户看的一行摘要：要跑什么 / 要改哪里
    var summary: String {
        if let command = payload["command"] as? String, !command.isEmpty {
            return "执行命令：\n\(command)"
        }
        if let commands = payload["command"] as? [String], !commands.isEmpty {
            return "执行命令：\n" + commands.joined(separator: "\n")
        }
        if let changes = payload["changes"] as? [[String: Any]], !changes.isEmpty {
            let paths = changes.compactMap { ($0["path"] as? String) ?? ($0["file"] as? String) }
            return "修改文件：\n" + paths.joined(separator: "\n")
        }
        if let reason = payload["reason"] as? String, !reason.isEmpty {
            return reason
        }
        return method.contains("command") ? "Codex 请求执行操作" : "Codex 请求修改文件"
    }

    var detail: String? {
        var parts: [String] = []
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty { parts.append("目录：\(cwd)") }
        if let reason = payload["reason"] as? String, !reason.isEmpty, summary.contains("执行") {
            parts.append("原因：\(reason)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

enum CodexApprovalDecision: String {
    case approved
    case approvedForSession = "approved_for_session"
    case denied
}

final class CodexApprovalCenter {
    static let shared = CodexApprovalCenter()

    private let lock = NSLock()
    private var sessionApprovedAll = false
    private var lastPromptAt: Date = .distantPast

    enum Policy: String {
        case ask, auto, deny
    }

    var policy: Policy {
        if let raw = UserDefaults.standard.string(forKey: "trollcodex.approval.policy"),
           let p = Policy(rawValue: raw.lowercased()) {
            return p
        }
        let path = NSHomeDirectory() + "/Documents/trollcodex-approval.txt"
        if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let p = Policy(rawValue: value) { return p }
        }
        return .ask
    }

    /// 会话内"全部允许"是否已开（新会话由 Models 在每次新请求前可选重置）
    var isSessionApprovedAll: Bool {
        lock.lock(); defer { lock.unlock() }
        return sessionApprovedAll
    }

    func resetSession() {
        lock.lock(); sessionApprovedAll = false; lock.unlock()
    }

    /// 异步决策：返回后由调用方回包给 codex（不回包会一直挂着）
    func resolve(_ request: CodexApprovalRequest,
                 completion: @escaping (CodexApprovalDecision) -> Void) {
        if isSessionApprovedAll {
            completion(.approved)
            return
        }
        switch policy {
        case .auto:
            completion(.approved)
            return
        case .deny:
            completion(.denied)
            return
        case .ask:
            break
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let host = Self.topViewController() else {
                completion(.denied)
                return
            }
            self.lock.lock()
            self.lastPromptAt = Date()
            self.lock.unlock()

            let alert = UIAlertController(title: "Codex 请求确认",
                                          message: [request.summary, request.detail]
                                                    .compactMap { $0 }
                                                    .joined(separator: "\n\n"),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "允许", style: .default) { _ in
                completion(.approved)
            })
            alert.addAction(UIAlertAction(title: "本会话内全部允许", style: .destructive) { [weak self] _ in
                self?.lock.lock(); self?.sessionApprovedAll = true; self?.lock.unlock()
                completion(.approvedForSession)
            })
            alert.addAction(UIAlertAction(title: "拒绝", style: .cancel) { _ in
                completion(.denied)
            })
            host.present(alert, animated: true)

            // 2 分钟没人点 → 按拒绝处理（避免 turn 永久挂住）
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                if alert.presentingViewController != nil {
                    alert.dismiss(animated: false)
                    completion(.denied)
                }
            }
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? scenes.flatMap { $0.windows }.first
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        if let nav = top as? UINavigationController, let visible = nav.visibleViewController {
            return visible
        }
        if let tab = top as? UITabBarController, let selected = tab.selectedViewController {
            return selected
        }
        return top
    }
}
