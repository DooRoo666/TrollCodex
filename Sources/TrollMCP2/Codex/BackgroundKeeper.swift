import Foundation
import UIKit

/// 让 codex 子进程在 App 退到后台后继续跑。
///
/// 原理：iOS 会把整个 App（连同它的子进程）挂起，除非持有后台任务。
/// 这里在每轮 codex turn 期间持有一个 `UIBackgroundTask`，turn 结束就释放；
/// 配合 entitlements 里的 `com.apple.private.background-task.allowed`
/// （TrollStore 安装时才能生效），把可执行时间从默认的 ~30 秒显著拉长。
///
/// 注意：这是「延长存活」，不是「永久后台」。系统最终仍会回收，
/// 所以 turn 结束后必须立刻 end()，否则会白白耗掉额度。
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private let lock = NSLock()
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var activeTurns = 0

    private init() {}

    var isHolding: Bool {
        lock.lock(); defer { lock.unlock() }
        return task != .invalid
    }

    /// 每轮 turn 开始调用（可重入，计数归零才真正释放）
    func begin(reason: String) {
        lock.lock()
        activeTurns += 1
        let alreadyHolding = (task != .invalid)
        if !alreadyHolding {
            task = UIApplication.shared.beginBackgroundTask(withName: "codex.\(reason)") { [weak self] in
                // 到期：不杀 codex，交给系统冻结；只清 token 防止泄漏
                NetworkLog.shared.log("[codex] background keep-alive 到期")
                self?.release()
            }
        }
        lock.unlock()
        if !alreadyHolding {
            NetworkLog.shared.log("[codex] background keep-alive 开始（\(reason)）")
        }
    }

    /// 每轮 turn 结束调用
    func end() {
        lock.lock()
        activeTurns = max(0, activeTurns - 1)
        let shouldRelease = (activeTurns == 0)
        lock.unlock()
        if shouldRelease { release() }
    }

    private func release() {
        lock.lock()
        let current = task
        task = .invalid
        activeTurns = 0
        lock.unlock()
        guard current != .invalid else { return }
        UIApplication.shared.endBackgroundTask(current)
        NetworkLog.shared.log("[codex] background keep-alive 结束")
    }
}
