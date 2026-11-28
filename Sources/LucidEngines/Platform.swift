import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif

/// The few things Lucid asks of the operating system that differ between macOS, Linux and
/// Windows: a free local port, a process's program name, and stopping a process.
enum Platform {
    /// What an engine's program file is called: `whisper-server`, or `whisper-server.exe` on Windows.
    static func programFile(_ name: String) -> String {
        #if os(Windows)
        return name + ".exe"
        #else
        return name
        #endif
    }

    /// Finds a program in the folders on the PATH.
    static func findOnPath(_ name: String) -> URL? {
        #if os(Windows)
        let separator: Character = ";"
        let variable = ProcessInfo.processInfo.environment.first { $0.key.uppercased() == "PATH" }?.value
        #else
        let separator: Character = ":"
        let variable = ProcessInfo.processInfo.environment["PATH"]
        #endif
        for folder in (variable ?? "").split(separator: separator) where !folder.isEmpty {
            let url = URL(fileURLWithPath: String(folder)).appendingPathComponent(programFile(name))
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// 127.0.0.1 as the four bytes a socket address holds.
    private static var loopback: UInt32 { UInt32(0x7F00_0001).bigEndian }

    /// Asks the system for a free local port.
    static func freePort() throws -> Int {
        #if os(Windows)
        var startup = WSADATA()
        guard WSAStartup(0x0202, &startup) == 0 else { throw EngineError.launchFailed("could not start networking") }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor != ~SOCKET(0) else { throw EngineError.launchFailed("could not open a socket") }
        defer { closesocket(descriptor) }

        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_port = 0
        address.sin_addr.S_un.S_addr = loopback
        var length = Int32(MemoryLayout<sockaddr_in>.size)
        #else
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw EngineError.launchFailed("could not open a socket") }
        defer { close(descriptor) }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: loopback)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif

        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        guard bound == 0 else { throw EngineError.launchFailed("could not reserve a local port") }

        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw EngineError.launchFailed("could not read the reserved port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// The file name of the program a process is running, without `.exe`. Nil when there is no
    /// such process, or it cannot be looked at.
    static func programName(ofProcess pid: Int32) -> String? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
        #elseif os(Windows)
        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else { return nil }
        defer { CloseHandle(process) }
        var buffer = [WCHAR](repeating: 0, count: 4096)
        var length = DWORD(buffer.count)
        guard QueryFullProcessImageNameW(process, 0, &buffer, &length) else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        #else
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe") else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
        #endif
    }

    /// Asks a process to stop. On Windows there is no asking, so it is stopped outright.
    static func terminate(pid: Int32) {
        #if os(Windows)
        guard let process = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(pid)) else { return }
        defer { CloseHandle(process) }
        TerminateProcess(process, 1)
        #else
        kill(pid, SIGTERM)
        #endif
    }

    /// Stops a process that did not stop when asked.
    static func forceStop(_ process: Process) {
        #if os(Windows)
        // `terminate()` already stops a Windows process outright. Nothing stronger exists.
        process.terminate()
        #else
        kill(process.processIdentifier, SIGKILL)
        #endif
    }

    /// Waits a twentieth of a second.
    static func pause() {
        Thread.sleep(forTimeInterval: 0.05)
    }
}
