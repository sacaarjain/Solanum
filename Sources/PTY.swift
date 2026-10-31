import Foundation
import Darwin

/// A child process (normally the user's shell) attached to a pseudo-terminal.
final class PTYProcess {
    let fd: Int32
    let pid: pid_t
    let shellName: String
    var onData: ((Data) -> Void)?
    var onExit: (() -> Void)?

    private let ioQueue = DispatchQueue(label: "solanum.pty.read")
    private let writeQueue = DispatchQueue(label: "solanum.pty.write")
    private var readSource: DispatchSourceRead?
    private var procSource: DispatchSourceProcess?
    private var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    private var finished = false
    private var closed = false

    private static let TIOCSWINSZ: UInt = 0x8008_7467

    init?(executable: String, args: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) {
        shellName = (executable as NSString).lastPathComponent

        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var t = PTYProcess.defaultTermios()

        // Prepare every C string before forking: the child may only call async-signal-safe functions.
        let cExe = strdup(executable)
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: args.count + 1)
        for (i, a) in args.enumerated() { argv[i] = strdup(a) }
        argv[args.count] = nil
        let envList = env.map { "\($0.key)=\($0.value)" }
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: envList.count + 1)
        for (i, e) in envList.enumerated() { envp[i] = strdup(e) }
        envp[envList.count] = nil
        let cDir = strdup(cwd ?? NSHomeDirectory())
        let cHome = strdup(NSHomeDirectory())

        var master: Int32 = -1
        let child = forkpty(&master, nil, &t, &ws)
        if child == 0 {
            if chdir(cDir) != 0 { _ = chdir(cHome) }
            execve(cExe, argv, envp)
            _exit(127)
        }

        free(cExe); free(cDir); free(cHome)
        for i in 0..<args.count { free(argv[i]) }
        argv.deallocate()
        for i in 0..<envList.count { free(envp[i]) }
        envp.deallocate()

        guard child > 0 else { return nil }
        fd = master
        pid = child
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    private static func defaultTermios() -> termios {
        var t = termios()
        t.c_iflag = tcflag_t(ICRNL | IXON | IXANY | IMAXBEL | BRKINT | IUTF8)
        t.c_oflag = tcflag_t(OPOST | ONLCR)
        t.c_cflag = tcflag_t(CREAD | CS8 | HUPCL)
        t.c_lflag = tcflag_t(ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL)
        withUnsafeMutableBytes(of: &t.c_cc) { raw in
            let cc = raw.bindMemory(to: cc_t.self)
            cc[Int(VEOF)] = 4
            cc[Int(VEOL)] = 255
            cc[Int(VEOL2)] = 255
            cc[Int(VERASE)] = 0x7F
            cc[Int(VWERASE)] = 0x17
            cc[Int(VKILL)] = 0x15
            cc[Int(VREPRINT)] = 0x12
            cc[Int(VINTR)] = 0x03
            cc[Int(VQUIT)] = 0x1C
            cc[Int(VSUSP)] = 0x1A
            cc[Int(VDSUSP)] = 0x19
            cc[Int(VSTART)] = 0x11
            cc[Int(VSTOP)] = 0x13
            cc[Int(VLNEXT)] = 0x16
            cc[Int(VDISCARD)] = 0x0F
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
            cc[Int(VSTATUS)] = 0x14
        }
        t.c_ispeed = speed_t(B38400)
        t.c_ospeed = speed_t(B38400)
        return t
    }

    func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let n = self.buffer.withUnsafeMutableBytes { read(self.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                let data = Data(self.buffer[0..<n])
                // Pause reading until the main thread has consumed this chunk (back-pressure keeps the UI responsive).
                src.suspend()
                DispatchQueue.main.async {
                    self.onData?(data)
                    src.resume()
                }
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                src.cancel()
                DispatchQueue.main.async { self.handleExit() }
            }
        }
        let fdToClose = fd
        src.setCancelHandler { close(fdToClose) }
        src.resume()
        readSource = src

        let ps = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)
        ps.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, WNOHANG)
            // Give the reader a moment to drain any final output.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.handleExit() }
        }
        ps.resume()
        procSource = ps
    }

    private func handleExit() {
        guard !finished else { return }
        finished = true
        onExit?()
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let fd = self.fd
        writeQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            var off = 0
            var spins = 0
            while off < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, bytes.count - off) }
                if n > 0 {
                    off += n
                } else if n < 0 && (errno == EAGAIN || errno == EINTR) && spins < 1000 {
                    spins += 1
                    usleep(1000)
                } else {
                    break
                }
            }
        }
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        var ws = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(cols, 1)),
                         ws_xpixel: UInt16(clamping: pixelWidth), ws_ypixel: UInt16(clamping: pixelHeight))
        _ = ioctl(fd, PTYProcess.TIOCSWINSZ, &ws)
    }

    /// Hangs up the child (if still running) and releases the PTY. Safe to call more than once.
    func terminate() {
        if !finished {
            finished = true
            // Listed first: once the shell and its jobs are gone, what they started no longer traces back to this pane.
            let nested = nestedJobGroups()
            kill(pid, SIGHUP)
            nested.forEach { killpg($0, SIGHUP) }
        }
        guard !closed else { return }
        closed = true
        // The read source's cancel handler closes the descriptor.
        readSource?.cancel()
        procSource?.cancel()
        let pid = self.pid
        writeQueue.async {
            var status: Int32 = 0
            // Reap without blocking forever.
            for _ in 0..<20 {
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                usleep(50_000)
            }
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    /// Process groups started by the shell's jobs rather than by the shell (a script with `set -m` gives each of its
    /// background jobs one). The shell hangs up its own jobs, unless they were disowned, but knows nothing of these, so
    /// they'd outlive the pane. What left the session (a daemon) or outlived its parent (already detached) isn't included.
    private func nestedJobGroups() -> Set<pid_t> {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var children: [pid_t: [(pid: pid_t, group: pid_t)]] = [:]
        for p in pids.prefix(Int(max(count, 0))) where p != pid && getsid(p) == pid {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            children[pid_t(info.pbi_ppid), default: []].append((p, pid_t(info.pbi_pgid)))
        }
        var stack = children[pid] ?? []
        var groups = Set<pid_t>()
        let shellGroups = Set(stack.map(\.group)).union([pid])
        while let p = stack.popLast() {
            groups.insert(p.group)
            stack += children[p.pid] ?? []
        }
        return groups.subtracting(shellGroups)
    }

    /// Name of the process currently in the foreground of this terminal (e.g. "vim").
    var foregroundProcessName: String? {
        let pg = tcgetpgrp(fd)
        guard pg > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 1024)
        let n = proc_name(pg, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    var hasForegroundJob: Bool {
        let pg = tcgetpgrp(fd)
        return pg > 0 && pg != pid
    }

    /// The coding agent (Claude Code, Codex, Gemini CLI, …) running in the foreground, if any.
    var foregroundAgent: AgentKind? {
        let pg = tcgetpgrp(fd)
        guard pg > 0, pg != pid else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let exe = proc_pidpath(pg, &path, UInt32(path.count)) > 0 ? String(cString: path) : ""
        return AgentKind.detect(name: foregroundProcessName ?? "", path: exe, args: PTYProcess.arguments(of: pg))
    }

    var foregroundIsClaudeCode: Bool { foregroundAgent == .claude }

    /// A process's argv, from KERN_PROCARGS2 (argc, the exec path, padding, then the arguments).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// The shell's current working directory (works without shell integration).
    var currentDirectory: String? { PTYProcess.directory(of: pid) }

    /// The foreground program's process (group leader), when one is running.
    var foregroundPID: pid_t? {
        let pg = tcgetpgrp(fd)
        return pg > 0 && pg != pid ? pg : nil
    }

    static func directory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}

/// Writes shell-integration scripts and builds the launch command for the user's shell.
enum ShellIntegration {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Solanum/shell")
    }

    static func install() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("zsh"), withIntermediateDirectories: true)
        try? (bashScript + sshWrapper + extras).write(to: dir.appendingPathComponent("solanum.bash"), atomically: true, encoding: .utf8)
        try? (zshScript + sshWrapper + extras).write(to: dir.appendingPathComponent("solanum.zsh"), atomically: true, encoding: .utf8)
        try? zshEnv.write(to: dir.appendingPathComponent("zsh/.zshenv"), atomically: true, encoding: .utf8)
    }

    static func userShell() -> String {
        let configured = Config.shared.shell.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty { return configured }
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    static func launchCommand() -> (exe: String, args: [String], env: [String: String]) {
        let shell = userShell()
        let name = (shell as NSString).lastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Solanum"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["SOLANUM_INTEGRATION_DIR"] = dir.path
        // Silence macOS bash's "default shell is now zsh" notice on every new tab.
        env["BASH_SILENCE_DEPRECATION_WARNING"] = "1"
        for k in ["TERM_SESSION_ID", "ITERM_SESSION_ID", "INSIDE_EMACS", "__CFBundleIdentifier", "XPC_SERVICE_NAME", "SOLANUM_BASH_LOGIN"] {
            env.removeValue(forKey: k)
        }
        guard Config.shared.shellIntegration else {
            return (shell, ["-" + name], env)
        }
        switch name {
        case "bash":
            env["SOLANUM_BASH_LOGIN"] = "1"
            return (shell, ["bash", "--init-file", dir.appendingPathComponent("solanum.bash").path, "-i"], env)
        case "zsh":
            if let z = env["ZDOTDIR"] { env["SOLANUM_ZDOTDIR"] = z }
            env["ZDOTDIR"] = dir.appendingPathComponent("zsh").path
            return (shell, ["-zsh"], env)
        default:
            return (shell, ["-" + name], env)
        }
    }

    /// Shared by bash and zsh. ssh runs as a multiplexing master on a private socket, announced to the
    /// terminal over OSC 1337, so the file sidebar can reuse the already-authenticated connection.
    /// Skipped when the user has their own ssh alias or function. Unless the user's config sets keepalives, ssh
    /// probes the server every 15 s, so a dead connection ends within 45 s instead of hanging the pane (and the
    /// sidebar's commands) until TCP gives up. The exit status is reported too (255: the connection was lost).
    static let sshWrapper = #"""
    if ! alias ssh >/dev/null 2>&1 && ! typeset -f ssh >/dev/null 2>&1; then
    function ssh {
        if [ ! -t 0 ] || [ ! -t 1 ]; then command ssh "$@"; return; fi
        local __solanum_d="$HOME/.config/solanum/ssh"
        mkdir -p "$__solanum_d" 2>/dev/null && chmod 700 "$__solanum_d" 2>/dev/null
        local __solanum_s="$__solanum_d/$$-$RANDOM$RANDOM"
        local __solanum_alive=()
        if command ssh -G "$@" 2>/dev/null | grep -qi '^serveraliveinterval 0$'; then
            __solanum_alive=(-o ServerAliveInterval=15 -o ServerAliveCountMax=3)
        fi
        printf '\033]1337;SolanumSSHArgs=%s\007' "$(printf '%q ' "$@" | base64 | tr -d '\n')" > /dev/tty
        printf '\033]1337;SolanumSSH=%s\007' "$__solanum_s" > /dev/tty
        command ssh -o ControlMaster=auto -o "ControlPath=$__solanum_s" -o ControlPersist=no "${__solanum_alive[@]}" "$@"
        local __solanum_ret=$?
        printf '\033]1337;SolanumSSHExit=%s\007' "$__solanum_ret" > /dev/tty
        printf '\033]1337;SolanumSSH=\007' > /dev/tty
        rm -f "$__solanum_s" 2>/dev/null
        return $__solanum_ret
    }
    fi

    """#

    /// Shared by bash and zsh: Settings › Aliases (re-read before each prompt, so edits apply to open tabs) and a
    /// `settings` command that opens the Settings window.
    static let extras = #"""
    __solanum_load_aliases() {
        # zsh doesn't word-split $vars; eval keeps the zsh-only syntax away from bash's parser.
        if [ -n "$ZSH_VERSION" ]; then eval 'set -- ${=__solanum_alias_names}'; else set -- $__solanum_alias_names; fi
        local __solanum_n
        for __solanum_n in "$@"; do unalias "$__solanum_n" 2>/dev/null; done
        [ -r "$SOLANUM_INTEGRATION_DIR/aliases.sh" ] && . "$SOLANUM_INTEGRATION_DIR/aliases.sh"
    }
    if ! type settings >/dev/null 2>&1; then
    function settings { printf '\033]1337;SolanumOpenSettings\007' > /dev/tty; }
    fi

    """#

    static let bashScript = #"""
    # Solanum shell integration for bash (loaded via --init-file).
    # Emulates a login shell, then adds hooks that mark prompts/commands with OSC 133.
    if [ -n "$SOLANUM_BASH_LOGIN" ]; then
        unset SOLANUM_BASH_LOGIN
        [ -r /etc/profile ] && . /etc/profile
        if [ -r "$HOME/.bash_profile" ]; then . "$HOME/.bash_profile"
        elif [ -r "$HOME/.bash_login" ]; then . "$HOME/.bash_login"
        elif [ -r "$HOME/.profile" ]; then . "$HOME/.profile"
        fi
    fi

    if [ -z "$__solanum_hooked" ] && [ -n "$PS1" ]; then
        __solanum_hooked=1
        # Append to the history file instead of overwriting it, so tabs don't erase each other's history.
        shopt -s histappend
        __solanum_running=0
        __solanum_ready=0

        __solanum_precmd() {
            local ret=$?
            if [ "$__solanum_running" = 1 ]; then
                printf '\033]133;D;%s\007' "$ret"
            fi
            __solanum_running=0
            printf '\033]7;file://%s%s\007' "${HOSTNAME:-localhost}" "$PWD"
            # Save each command as it runs so ⌃H history includes other tabs' commands.
            builtin history -a 2>/dev/null
            __solanum_load_aliases
            return $ret
        }

        __solanum_postcmd() {
            case "$PS1" in *'133;A'*) ;; *) PS1='\[\033]133;A\007\]'"$PS1" ;; esac
            case "$PS1" in *'133;B'*) ;; *) PS1="$PS1"'\[\033]133;B\007\]' ;; esac
            __solanum_ready=1
        }

        __solanum_preexec() {
            case "$BASH_COMMAND" in __solanum_precmd*) __solanum_ready=0; return ;; esac
            [ -n "$COMP_LINE" ] && return
            if [ "$__solanum_ready" = 1 ]; then
                __solanum_ready=0
                __solanum_running=1
                printf '\033]133;C\007'
            fi
        }

        if [ -n "$PROMPT_COMMAND" ]; then
            PROMPT_COMMAND="__solanum_precmd; ${PROMPT_COMMAND%;}; __solanum_postcmd"
        else
            PROMPT_COMMAND="__solanum_precmd; __solanum_postcmd"
        fi
        if [ -z "$(trap -p DEBUG)" ]; then
            trap '__solanum_preexec' DEBUG
        fi
    fi

    """#

    static let zshEnv = #"""
    # Solanum: restore the user's ZDOTDIR, load their .zshenv, then install integration.
    if [[ -n "${SOLANUM_ZDOTDIR-}" ]]; then
        ZDOTDIR="$SOLANUM_ZDOTDIR"
        unset SOLANUM_ZDOTDIR
    else
        unset ZDOTDIR
    fi
    [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && source "${ZDOTDIR:-$HOME}/.zshenv"
    if [[ -o interactive && -r "$SOLANUM_INTEGRATION_DIR/solanum.zsh" ]]; then
        source "$SOLANUM_INTEGRATION_DIR/solanum.zsh"
    fi

    """#

    static let zshScript = #"""
    # Solanum shell integration for zsh.
    typeset -gi _solanum_running=0
    _solanum_precmd() {
        local ret=$?
        (( _solanum_running )) && print -n "\e]133;D;${ret}\a"
        _solanum_running=0
        print -n "\e]7;file://${HOST}${PWD}\a"
        __solanum_load_aliases
        precmd_functions=(${precmd_functions:#_solanum_post} _solanum_post)
        return $ret
    }
    _solanum_post() {
        [[ "$PS1" == *'133;A'* ]] || PS1=$'%{\e]133;A\a%}'"$PS1"
        [[ "$PS1" == *'133;B'* ]] || PS1="$PS1"$'%{\e]133;B\a%}'
    }
    _solanum_preexec() {
        _solanum_running=1
        print -n "\e]133;C\a"
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _solanum_precmd
    add-zsh-hook preexec _solanum_preexec
    # _solanum_precmd moves _solanum_post to the end for the next prompt; zsh has already listed this prompt's hooks
    # by then, so it's added now too, or the first prompt has no marks (and a restored `claude -c` waits for a key).
    add-zsh-hook precmd _solanum_post

    """#
}
