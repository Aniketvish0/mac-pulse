import Darwin
import Foundation

struct RawProc {
    let pid: Int32
    let ppid: Int32
    let uid: uid_t
    var path: String
    let mem: UInt64
    let cpuSeconds: Double
    let measured: Bool
    var cpu: Double = 0
    var script: String?
    var argv0: String?
}

enum ProcessReader {
    static let secondsPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    static func read() -> [Int32: RawProc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [:] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var kinfos = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = kinfos.count * stride
        guard sysctl(&mib, 4, &kinfos, &size, nil, 0) == 0 else { return [:] }

        var out: [Int32: RawProc] = [:]
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for var k in kinfos.prefix(size / stride) {
            let pid = k.kp_proc.p_pid
            let comm = withUnsafeBytes(of: &k.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let path = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 ? String(cString: pathBuf) : comm
            var info = rusage_info_v4()
            let measured = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } == 0
            out[pid] = RawProc(
                pid: pid, ppid: k.kp_eproc.e_ppid, uid: k.kp_eproc.e_ucred.cr_uid, path: path,
                mem: measured ? info.ri_phys_footprint : 0,
                cpuSeconds: measured ? Double(info.ri_user_time + info.ri_system_time) * secondsPerTick : 0,
                measured: measured
            )
        }
        return out
    }

    struct Launch { let exec: String; let argv0: String?; let script: String? }

    static func launch(pid: Int32) -> Launch? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 16_384
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }
        let exec = String(decoding: buf[4..<i], as: UTF8.self)
        while i < size, buf[i] == 0 { i += 1 }
        var args: [String] = []
        while i < size, args.count < argc {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        let extensions = [".js", ".mjs", ".cjs", ".ts", ".py", ".rb"]
        let script = Catalog.devRuntimes.contains((exec as NSString).lastPathComponent)
            ? args.dropFirst().first { !$0.hasPrefix("-") && extensions.contains(where: $0.hasSuffix) }.map { ($0 as NSString).lastPathComponent }
            : nil
        return Launch(exec: exec, argv0: args.first.map { $0.trimmingCharacters(in: .whitespaces) }, script: script)
    }
}

enum Catalog {
    static let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/", "/Library/PrivilegedHelperTools/"]
    static let devRuntimes: Set<String> = ["node", "python", "python3", "bun", "deno", "ruby", "java", "esbuild", "vite", "next-server", "turbo", "uv", "go"]
    static let keywords: [(String, [String])] = [
        ("browsers", ["brave", "chrome", "chromium", "safari", "firefox", "arc", "dia", "edge", "opera", "vivaldi", "orion", "zen"]),
        ("ai", ["claude", "chatgpt", "ollama", "lm studio", "llama", "codex", "copilot", "perplexity", "gemini", "wispr", "superwhisper", "mlx"]),
        ("comms", ["slack", "discord", "zoom", "teams", "messages", "mail", "telegram", "whatsapp", "signal", "facetime", "superhuman", "spark", "linear", "notion", "granola"]),
        ("media", ["spotify", "music", "photos", "figma", "preview", "quicktime", "vlc", "iina", "sketch", "photoshop", "final cut", "logic", "obs", "podcasts", "tv", "canva"]),
        ("dev", ["code", "cursor", "xcode", "t3", "zed", "iterm", "terminal", "ghostty", "warp", "wezterm", "alacritty", "kitty", "docker", "orbstack",
                 "postman", "android studio", "intellij", "pycharm", "webstorm", "tower", "fork", "github", "simulator", "node", "python", "bun", "deno",
                 "ruby", "java", "go", "cargo", "rustc", "rust-analyzer", "tsserver", "clangd", "git", "esbuild", "vite", "npm", "pnpm", "yarn", "postgres",
                 "redis", "mongod", "mysqld", "qemu", "gopls", "sourcekit-lsp", "turbo", "next-server", "uv", "tmux", "zsh", "bash", "ssh"]),
    ]

    private static var categoryCache: [String: String] = [:]
    private static var bundleIdCache: [String: String?] = [:]

    static func category(_ name: String) -> String {
        if let hit = categoryCache[name] { return hit }
        let lower = Array(name.lowercased().utf8)
        let isLetter = { (b: UInt8) in b >= 97 && b <= 122 }
        func matches(_ key: String) -> Bool {
            let k = Array(key.utf8)
            guard k.count <= lower.count else { return false }
            for start in 0...(lower.count - k.count) where Array(lower[start..<start + k.count]) == k {
                let before = start == 0 || !isLetter(lower[start - 1])
                let after = start + k.count == lower.count || !isLetter(lower[start + k.count])
                if before && after { return true }
            }
            return false
        }
        let cat = keywords.first { $0.1.contains(where: matches) }?.0 ?? "other"
        categoryCache[name] = cat
        return cat
    }

    static func bundleId(_ bundlePath: String) -> String? {
        if let hit = bundleIdCache[bundlePath] { return hit }
        let id = Bundle(path: bundlePath)?.bundleIdentifier
        bundleIdCache[bundlePath] = id
        return id
    }
}

struct GroupKey {
    let id: String
    let name: String
    let kind: String
    let bundle: String?
    let system: Bool
}

enum Grouping {
    static let me = getuid()
    static let home = NSHomeDirectory()

    static func key(for p: RawProc) -> GroupKey {
        let parts = p.path.split(separator: "/", omittingEmptySubsequences: false)
        if let idx = parts.indices.first(where: { $0 > 0 && parts[$0].hasSuffix(".app") }) {
            let bundle = parts[...idx].joined(separator: "/")
            let name = String(parts[idx].dropLast(4))
            let userApp = bundle.contains("/Applications/") && p.uid == me
            let system = !userApp && (p.uid != me || Catalog.systemPrefixes.contains(where: bundle.hasPrefix))
            return GroupKey(id: "app:\(bundle)", name: name, kind: "app", bundle: bundle, system: system)
        }
        let base = (p.path as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        let system = p.uid != me || Catalog.systemPrefixes.contains(where: p.path.hasPrefix)
        return GroupKey(id: "cmd:\(base):\(system ? "sys" : "user")", name: base.isEmpty ? p.path : base, kind: "cmd", bundle: nil, system: system)
    }

    static func build(_ procs: [Int32: RawProc], wired: UInt64, unmeasuredCPU: Double) -> [Group] {
        var members: [String: (key: GroupKey, procs: [RawProc])] = [:]
        var owner: [Int32: GroupKey] = [:]
        var unmeasured: [RawProc] = []
        for p in procs.values {
            guard p.measured else { unmeasured.append(p); continue }
            let k = key(for: p)
            members[k.id, default: (k, [])].procs.append(p)
            owner[p.pid] = k
        }

        var protected = Set<String>()
        var pid = getpid()
        while let p = procs[pid], pid > 1 {
            if let k = owner[pid] { protected.insert(k.id) }
            pid = p.ppid
        }

        func parentApp(_ p: RawProc) -> String? {
            var pid = p.ppid
            for _ in 0..<64 {
                guard pid > 1, let parent = procs[pid] else { return nil }
                if let k = owner[pid], k.kind == "app" { return k.name }
                pid = parent.ppid
            }
            return nil
        }

        func shortName(_ p: RawProc, _ k: GroupKey) -> String {
            let base = (p.path as NSString).lastPathComponent
            if k.kind == "cmd", let script = p.script { return "\(k.name) \(script)" }
            let trimmed = base.replacingOccurrences(of: k.name, with: "").trimmingCharacters(in: CharacterSet(charactersIn: " -"))
            return trimmed.isEmpty ? base : trimmed
        }

        func group(_ k: GroupKey, _ list: [RawProc]) -> Group {
            let top: [GroupProc] = list.sorted { $0.mem > $1.mem }.prefix(80).map { p in
                GroupProc(pid: p.pid, ppid: p.ppid, name: shortName(p, k), path: p.path, argv0: p.argv0 ?? p.path, mem: p.mem, cpu: p.cpu,
                          parentApp: k.kind == "cmd" ? parentApp(p) : nil)
            }
            let mem: UInt64 = list.reduce(0) { $0 + $1.mem }
            let cpu: Double = list.reduce(0) { $0 + $1.cpu }
            let bundleId: String? = k.kind == "app" && !k.system ? k.bundle.flatMap(Catalog.bundleId) : nil
            return Group(
                id: k.id, name: k.name, kind: k.kind, cat: k.system ? "system" : Catalog.category(k.name), system: k.system,
                bundle: k.bundle, bundleId: bundleId, protected: protected.contains(k.id), unmeasured: false,
                mem: mem, cpu: round1(cpu), count: list.count, procs: top
            )
        }

        var groups = members.values.map { group($0.key, $0.procs) }
        groups.append(Group(
            id: "kernel:wired", name: "Kernel & drivers (wired)", kind: "cmd", cat: "system", system: true, bundle: nil, bundleId: nil,
            protected: false, unmeasured: false, mem: wired, cpu: 0, count: 0, procs: []
        ))
        if !unmeasured.isEmpty {
            groups.append(Group(
                id: "cmd:unmeasured:sys", name: "Root & system processes", kind: "cmd", cat: "system", system: true, bundle: nil, bundleId: nil,
                protected: false, unmeasured: true, mem: 0, cpu: round1(unmeasuredCPU), count: unmeasured.count,
                procs: unmeasured.sorted { $0.pid < $1.pid }.prefix(80).map {
                    GroupProc(pid: $0.pid, ppid: $0.ppid, name: ($0.path as NSString).lastPathComponent, path: $0.path, argv0: $0.path, mem: 0, cpu: 0, parentApp: nil)
                }
            ))
        }
        return groups.sorted { $0.mem > $1.mem }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func tilde(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func recommend(_ groups: [Group]) -> [Rec] {
        let mb: UInt64 = 1 << 20
        var recs: [Rec] = []
        for g in groups where !g.system && !g.protected {
            if g.kind == "app" {
                let quit = "osascript -e " + shellQuote(g.bundleId.map { "quit app id \"\($0)\"" } ?? "quit app \"\(g.name)\"")
                let idle = g.cpu < 3
                func rec(_ section: String, _ reason: String) -> Rec {
                    Rec(id: g.id, groupId: g.id, pid: nil, title: g.name, mem: g.mem, cpu: g.cpu, command: quit,
                        path: tilde(g.bundle ?? ""), section: section, reason: reason)
                }
                if idle, ["comms", "media", "other"].contains(g.cat), g.mem >= 200 * mb {
                    recs.append(rec("safe", "Idle, \(g.count) processes"))
                } else if g.mem >= 400 * mb || g.cpu >= 30 {
                    var reason = ["browsers": "Tabs come back on reopen", "dev": "Save open work first", "ai": "Stops running agents or models"][g.cat]
                        ?? (idle ? "Idle but large" : "In use")
                    if g.cpu >= 10 { reason = "\(Int(g.cpu.rounded()))% CPU right now. \(reason)" }
                    recs.append(rec("review", reason))
                }
                continue
            }
            for p in g.procs {
                let kill = "[ \"$(ps -o comm= -p \(p.pid))\" = \(shellQuote(p.argv0)) ] && kill \(p.pid) || echo \"skipped \(p.pid): it is no longer the same program\""
                func rec(_ reason: String) -> Rec {
                    Rec(id: "pid:\(p.pid)", groupId: g.id, pid: p.pid, title: "\(p.name) · pid \(p.pid)", mem: p.mem, cpu: p.cpu,
                        command: kill, path: tilde(p.path), section: "review", reason: reason)
                }
                if p.ppid == 1, Catalog.devRuntimes.contains(g.name), p.mem >= 50 * mb, p.cpu < 2 {
                    recs.append(rec("Detached from any app and idle. May be a background worker"))
                } else if p.cpu >= 50 || p.mem >= 1024 * mb {
                    let who = p.parentApp.map { "started by \($0)" } ?? "no parent app"
                    recs.append(rec("\(p.cpu >= 50 ? "\(Int(p.cpu.rounded()))% CPU" : "over 1 GB"), \(who)"))
                }
            }
        }
        return recs.sorted { ($0.section == "safe" ? 0 : 1, -Double($0.mem)) < ($1.section == "safe" ? 0 : 1, -Double($1.mem)) }
    }
}
