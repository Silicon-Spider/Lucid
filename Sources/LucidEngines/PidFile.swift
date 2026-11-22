import Foundation

/// Remembers the engine process IDs, so a later launch can stop engines left behind by a crash.
public enum PidFile {
    public static func write(_ pids: [Int32], to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(pids).write(to: url, options: .atomic)
    }

    public static func read(at url: URL) -> [Int32] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Int32].self, from: data)) ?? []
    }

    public static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Stops every recorded process that is still running one of the named programs, then
    /// removes the file. The name check matters: the system may have reused a PID for
    /// something unrelated.
    public static func killStale(at url: URL, names: Set<String>) {
        for pid in read(at: url) where pid > 0 {
            if let name = executableName(of: pid), names.contains(name) {
                kill(pid, SIGTERM)
            }
        }
        remove(at: url)
    }

    static func executableName(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}
