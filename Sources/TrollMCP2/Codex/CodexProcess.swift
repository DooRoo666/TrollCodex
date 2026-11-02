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
final class CodexProcess {
    private(set) var pid: pid_t = 0
    private var stdinFD: Int32 = -1
    private var stdoutFD: Int32 = -1
    private var buffer = [UInt8]()
    private let readQueue = DispatchQueue(label: "trollcodex.process.read")

    var onLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    func start(binary: String, arguments: [String], environment: [String: String]) throws {
        var inPipe = [Int32](repeating: 0, count: 2)
        var outPipe = [Int32](repeating: 0, count: 2)
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0 else { throw CodexProcessError.pipeFailed }

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, inPipe[1])
        posix_spawn_file_actions_addclose(&actions, outPipe[0])

        var argv: [UnsafeMutablePointer<CChar>?] = ([binary] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, binary, &actions, nil, argv, envp)

        argv.forEach { free($0) }
        envp.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)

        close(inPipe[0])
        close(outPipe[1])

        guard rc == 0 else {
            close(inPipe[1])
            close(outPipe[0])
            throw CodexProcessError.spawnFailed(rc)
        }

        pid = childPID
        stdinFD = inPipe[1]
        stdoutFD = outPipe[0]
        readQueue.async { [weak self] in self?.readLoop() }
    }

    func write(line: String) {
        guard stdinFD >= 0, let data = (line + "\n").data(using: .utf8) else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(stdinFD, base.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    func terminate() {
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
        if stdoutFD >= 0 { close(stdoutFD); stdoutFD = -1 }
        if pid > 0 { kill(pid, SIGTERM); pid = 0 }
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while stdoutFD >= 0 {
            let fd = stdoutFD
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
        onExit?(0)
    }
}
