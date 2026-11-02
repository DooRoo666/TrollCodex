import Foundation

enum CodexProcessError: LocalizedError {
    case pipeFailed
    case spawnFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .pipeFailed:
            return "pipe() 创建失败"
        case .spawnFailed(let code):
            return "posix_spawn 失败 (errno \(code))"
        }
    }
}

/// 最小可用的子进程封装：posix_spawn + 三条标准流。
/// iOS 没有 Process/NSTask，只能走 posix_spawn（fork 在 iOS 上不可用）。
///
/// 稳定性修正（相对旧版）：
///   · 读线程只持有自己的局部 fd，不再和 terminate() 抢同一个成员变量
///     （旧版 terminate 关 fd 后读线程还能在已关闭/被复用的 fd 上阻塞读）
///   · 退出码用 waitpid 取真值（旧版固定回调 0，进程崩了也显示正常退出）
///   · 关闭动作幂等（重复 terminate / deinit 不会 double close）
final class CodexProcess {
    private(set) var pid: pid_t = 0

    private static let sigpipeLock = NSLock()
    private static var sigpipeIgnored = false

    /// 只做一次：SIGPIPE 全局忽略（否则子进程死后写管道会直接把 App 干掉）
    static func ignoreSIGPIPEOnce() {
        sigpipeLock.lock()
        defer { sigpipeLock.unlock() }
        guard !sigpipeIgnored else { return }
        sigpipeIgnored = true
        _ = signal(SIGPIPE, SIG_IGN)
    }

    private let ioLock = NSLock()
    private var stdinFD: Int32 = -1
    private var terminated = false

    private let readQueue = DispatchQueue(label: "trollcodex.process.read")

    var onLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    func start(binary: String, arguments: [String], environment: [String: String]) throws {
        // 子进程随时可能崩掉；崩掉后我们可能还在往已关闭的 stdin 管道里写 → SIGPIPE 直接杀进程。
        // 全局忽略一次，写入失败靠 write() 的返回值判断（NanoCode 那边也是这么做的）。
        CodexProcess.ignoreSIGPIPEOnce()

        var inPipe = [Int32](repeating: 0, count: 2)
        var outPipe = [Int32](repeating: 0, count: 2)
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0 else { throw CodexProcessError.pipeFailed }

        // Darwin 上这两个类型是 pointer typedef（不是有 init() 的 struct），
        // 必须声明成可选指针再传 &x 给 init/setflags（CI 实测：`posix_spawn_file_actions_t()` 直接报
        // "missing argument for parameter #1 in call"）
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, inPipe[1])
        posix_spawn_file_actions_addclose(&actions, outPipe[0])

        // 信号默认动作/屏蔽集：避免父进程的忽略态被子进程继承（codex 自己会装 handler）
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var argv: [UnsafeMutablePointer<CChar>?] = ([binary] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, binary, &actions, &attr, argv, envp)

        argv.forEach { free($0) }
        envp.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)

        close(inPipe[0])
        close(outPipe[1])

        guard rc == 0 else {
            close(inPipe[1])
            close(outPipe[0])
            throw CodexProcessError.spawnFailed(rc)
        }

        let writeFD = inPipe[1]
        let readFD = outPipe[0]
        ioLock.lock()
        pid = childPID
        stdinFD = writeFD
        terminated = false
        ioLock.unlock()

        readQueue.async { [weak self] in
            self?.readLoop(fd: readFD, child: childPID)
        }
    }

    func write(line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        ioLock.lock()
        let fd = stdinFD
        ioLock.unlock()
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    func terminate() {
        ioLock.lock()
        if terminated {
            ioLock.unlock()
            return
        }
        terminated = true
        let fd = stdinFD
        let child = pid
        stdinFD = -1
        ioLock.unlock()

        // 先关写端：子进程读到 EOF 会自己收尾；再补一刀 SIGTERM 兜底不听话的
        if fd >= 0 { close(fd) }
        if child > 0 { kill(child, SIGTERM) }
    }

    /// 读线程：fd 与 pid 都是自己的局部变量，绝不被外部 close 打乱
    private func readLoop(fd: Int32, child: pid_t) {
        var chunk = [UInt8](repeating: 0, count: 8192)
        var buffer = [UInt8]()

        while true {
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return read(fd, base, raw.count)
            }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let idx = buffer.firstIndex(of: 0x0A) {
                let lineBytes = Array(buffer[0..<idx])
                buffer.removeFirst(idx + 1)
                if let line = String(bytes: lineBytes, encoding: .utf8), !line.isEmpty {
                    onLine?(line)
                }
            }
        }

        if !buffer.isEmpty, let last = String(bytes: buffer, encoding: .utf8), !last.isEmpty {
            onLine?(last)
        }
        close(fd)

        // 取真实退出状态（被信号杀掉时 status 高位非 0）
        var status: Int32 = 0
        let waited = waitpid(child, &status, 0)
        let code: Int32
        if waited == child {
            let signal = status & 0x7F
            let exitCode = (status >> 8) & 0xFF
            code = signal != 0 ? 128 + signal : exitCode
        } else {
            code = -1
        }

        ioLock.lock()
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
        pid = 0
        ioLock.unlock()

        onExit?(code)
    }

    deinit {
        terminate()
    }
}
