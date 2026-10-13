import Foundation
import Darwin

/// Files programs have open right now. Moving a folder that a running program writes into puts that program's
/// files in the Trash, where it keeps writing, and Finder then refuses to empty the Trash ("it's being used by
/// another task"). Spare checks this before offering or moving anything.
public enum OpenFiles {
    /// Open files of every process Spare may look at (the person's own, which is where their apps and agents run),
    /// as path → process name. Read the way lsof does, through libproc.
    public static func snapshot() -> [String: String] {
        var result: [String: String] = [:]
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return result }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 32)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let me = getpid()
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 0 && pid != me {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 8)
            let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
            guard used > 0 else { continue }
            var name: String?
            for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let read = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
                guard read == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { continue }
                let path = withUnsafePointer(to: &info.pvip.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
                guard path.hasPrefix("/") else { continue }
                if name == nil { name = processName(pid) }
                result[path] = name ?? "another program"
                // The kernel reports /private/var and /private/tmp; Foundation usually says /var and /tmp.
                for alias in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(alias) {
                    result[String(path.dropFirst("/private".count))] = name ?? "another program"
                }
            }
        }
        return result
    }

    /// macOS's record of which app a helper works for (WebKit's networking process for the browser that started it,
    /// a virtual machine for Docker). Exported by libSystem but not in its headers, so looked up at run time.
    private static let responsible: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    static func processName(_ pid: pid_t) -> String {
        let owner = responsible.map { $0(pid) } ?? pid
        return name(of: owner > 0 ? owner : pid) ?? name(of: pid) ?? "another program"
    }

    /// The app's name for processes inside an app, so "Claude" rather than "Claude Helper"; otherwise the program's file name.
    private static func name(of pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let full = String(cString: path)
        if let range = full.range(of: ".app/") {
            return URL(fileURLWithPath: String(full[..<range.lowerBound])).deletingPathExtension().lastPathComponent
        }
        return URL(fileURLWithPath: full).lastPathComponent
    }

    /// The program using something inside a file or folder, if any.
    public static func user(of url: URL, in open: [String: String]) -> String? {
        let base = url.path
        if let exact = open[base] { return exact }
        let prefix = base + "/"
        return open.first { $0.key.hasPrefix(prefix) }?.value
    }

    /// Marks items with open files inside: they are never selected, and say who is using them.
    public static func mark(_ items: [Item], with open: [String: String]) -> [Item] {
        guard !open.isEmpty else { return items }
        // Every folder above an open file, so each item needs one lookup per path.
        var owners: [String: String] = [:]
        for (path, process) in open {
            var url = URL(fileURLWithPath: path)
            while url.path != "/" && owners[url.path] == nil {
                owners[url.path] = process
                url.deleteLastPathComponent()
            }
        }
        return items.map { item in
            guard let user = item.urls.lazy.compactMap({ owners[$0.path] }).first else { return item }
            var marked = item
            marked.inUseBy = user
            marked.suggested = false
            return marked
        }
    }
}
