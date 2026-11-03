import Darwin
import Foundation

/// A login shell on a pseudo-terminal, attached to a named tmux session when
/// tmux is installed. The tmux session outlives the connection, so a phone
/// that drops off (iOS suspends apps) reattaches to the same running programs.
final class Terminal {
    private let master: Int32
    private let pid: pid_t
    private var reader: DispatchSourceRead?
    private var exitWatch: DispatchSourceProcess?
    private var closed = false

    init?(name: String, cols: Int, rows: Int, queue: DispatchQueue,
          onOutput: @escaping (Data) -> Void, onExit: @escaping () -> Void) {
        let shell = Self.loginShell()
        let session = Wire.sessionName(name)
        let script = "if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s \(session); "
            + "else exec \(shell) -l; fi"
        let home = NSHomeDirectory()
        let env = [
            "TERM=xterm-256color", "COLORTERM=truecolor", "LANG=en_US.UTF-8",
            "HOME=\(home)", "USER=\(NSUserName())", "LOGNAME=\(NSUserName())", "SHELL=\(shell)",
            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        // Everything the child needs is made before fork: after it, only exec.
        let argv = Self.cStrings([shell, "-l", "-c", script])
        let envp = Self.cStrings(env)
        let cwd = strdup(home)
        defer {
            Self.free(argv); Self.free(envp); Darwin.free(cwd)
        }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let child = forkpty(&fd, nil, nil, &size)
        if child == 0 {
            chdir(cwd)
            execve(argv[0], argv, envp)
            _exit(127)
        }
        guard child > 0 else { return nil }
        master = fd
        pid = child
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        let r = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        r.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(self.master, &buf, buf.count)
            if n > 0 { onOutput(Data(buf[0..<n])) }
            else if n == 0 || (errno != EAGAIN && errno != EINTR) { self.reader?.cancel() }
        }
        r.setCancelHandler { [master] in Darwin.close(master) }
        r.resume()
        reader = r

        let e = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        e.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, 0)
            self.exitWatch?.cancel()
            self.reader?.cancel()
            onExit()
        }
        e.resume()
        exitWatch = e
    }

    func write(_ data: Data) {
        guard !closed else { return }
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(master, raw.baseAddress! + off, raw.count - off)
                if n > 0 { off += n } else if errno != EAGAIN && errno != EINTR { break } else { usleep(1000) }
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard !closed else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// Hangs up the shell. tmux detaches and keeps the session; a plain shell exits.
    func close() {
        guard !closed else { return }
        closed = true
        kill(pid, SIGHUP)
        reader?.cancel()
    }

    /// Ends a tmux session by name (exact match), if tmux is installed.
    static func killSession(_ name: String) {
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        p.arguments = ["kill-session", "-t", "=\(name)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        return "/bin/zsh"
    }

    private static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }

    private static func free(_ list: [UnsafeMutablePointer<CChar>?]) {
        list.forEach { Darwin.free($0) }
    }
}
