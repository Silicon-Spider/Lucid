import Foundation

/// The programs the tests start, found on whichever system they run on.
enum TestTools {
    /// Looks for a program in the folders on the PATH.
    private static func onPath(_ names: [String]) -> URL? {
        // Windows spells the variable "Path", and separates folders with a semicolon.
        let variable = ProcessInfo.processInfo.environment.first { $0.key.uppercased() == "PATH" }?.value ?? ""
        #if os(Windows)
        let separator: Character = ";"
        #else
        let separator: Character = ":"
        #endif
        for folder in variable.split(separator: separator) {
            for name in names {
                let url = URL(fileURLWithPath: String(folder)).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Python 3, which the tests use as a small local web server.
    static var python: URL {
        #if os(Windows)
        // "python3.exe" can be a stub that opens the Microsoft Store, so "python.exe" comes first.
        return onPath(["python.exe", "python3.exe"]) ?? URL(fileURLWithPath: "python.exe")
        #else
        let system = "/usr/bin/python3"
        if FileManager.default.isExecutableFile(atPath: system) { return URL(fileURLWithPath: system) }
        return onPath(["python3", "python"]) ?? URL(fileURLWithPath: system)
        #endif
    }

    /// A program that stops at once with an error, and the arguments that make it do so.
    static var failing: (executable: URL, arguments: [String]) {
        #if os(Windows)
        let shell = ProcessInfo.processInfo.environment.first { $0.key.uppercased() == "COMSPEC" }?.value
        return (URL(fileURLWithPath: shell ?? "C:\\Windows\\System32\\cmd.exe"), ["/c", "exit 1"])
        #else
        let path = ["/usr/bin/false", "/bin/false"].first { FileManager.default.isExecutableFile(atPath: $0) }
        return (URL(fileURLWithPath: path ?? "/usr/bin/false"), [])
        #endif
    }
}
