import Foundation

/// What a model file holds, found by reading the start of the file.
public enum ModelFormat: Equatable, Sendable {
    /// A Whisper speech model in whisper.cpp's own format, usually a `.bin` file.
    case whisper
    /// A model in llama.cpp's GGUF format.
    case gguf(GGUFInfo)

    /// The kind of model this format is used for in Lucid.
    public var kind: ModelKind {
        switch self {
        case .whisper: return .speech
        case .gguf: return .cleanup
        }
    }
}

/// The few GGUF metadata values Lucid checks before it accepts a cleanup model.
public struct GGUFInfo: Equatable, Sendable {
    public var version: UInt32
    /// `general.architecture`, such as "llama" or "qwen3". "clip" is a vision add-on.
    public var architecture: String?
    /// `general.type`: "model", or "adapter" and "mmproj" for files that are not a model by themselves.
    public var type: String?
    /// `split.count`: how many files the model is split into.
    public var splitCount: Int
    /// Whether the file has a default chat template. Nil when the metadata could not be judged.
    public var hasChatTemplate: Bool?

    public init(
        version: UInt32,
        architecture: String? = nil,
        type: String? = nil,
        splitCount: Int = 1,
        hasChatTemplate: Bool? = nil
    ) {
        self.version = version
        self.architecture = architecture
        self.type = type
        self.splitCount = splitCount
        self.hasChatTemplate = hasChatTemplate
    }
}

/// Why a model file was not accepted, in words the user can act on.
public enum ModelError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case notAModel
    /// The file is a model, but of the other kind.
    case wrongKind(ModelKind)
    /// A GGUF file that only works alongside a main model, such as a vision add-on.
    case notStandalone(String)
    case split(Int)
    case oldFormat
    case damaged
    case alreadyInstalled(String)
    case builtIn(String)
    case notFound(String)
    case copyFailed(String)
    case removeFailed(String)
    /// Another model already has this name.
    case nameTaken(String)
    /// The name is longer than this many characters.
    case nameTooLong(Int)

    public var description: String {
        switch self {
        case .unreadable(let name):
            return "\(name) could not be read."
        case .notAModel:
            return "This is not a model file Lucid can use. Speech models are Whisper models for whisper.cpp, "
                + "usually named ggml-something.bin. Cleanup models are .gguf files."
        case .wrongKind(.speech):
            return "This is a Whisper speech model, not a cleanup model. Add it as a speech model instead."
        case .wrongKind(.cleanup):
            return "This is a GGUF model for cleanup, not a speech model. Add it as a cleanup model instead."
        case .notStandalone(let what):
            return "This file is \(what), not a model by itself. Choose the main model file instead."
        case .split(let count):
            return "This model is split into \(count) files. Lucid can only add a model that is a single file."
        case .oldFormat:
            return "This GGUF file uses an old format that llama.cpp no longer reads. Download a newer copy."
        case .damaged:
            return "This model file is incomplete or damaged. Download it again."
        case .alreadyInstalled(let name):
            return "A model called \(name) is already in Lucid's models folder."
        case .builtIn(let name):
            return "\(name) is one of Lucid's own models, and its prompt format is fixed."
        case .notFound(let name):
            return "\(name) is not in Lucid's models folder."
        case .copyFailed(let reason):
            return "The model could not be copied into Lucid's models folder: \(reason)"
        case .removeFailed(let reason):
            return "The model could not be removed: \(reason)"
        case .nameTaken(let name):
            return "Another model is already called \(name). Choose a different name."
        case .nameTooLong(let limit):
            return "That name is too long. Use \(limit) characters or fewer."
        }
    }
}

/// Reads the start of a model file to find out what it is, without loading the model.
public enum ModelFile {
    /// whisper.cpp's file magic, 0x67676d6c, as it is stored on disk.
    static let whisperMagic = Data("lmgg".utf8)
    static let ggufMagic = Data("GGUF".utf8)

    /// The kind of model a file holds, judged by its first four bytes only. Nil for anything else.
    public static func kind(of url: URL) -> ModelKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4) else { return nil }
        switch magic {
        case whisperMagic: return .speech
        case ggufMagic: return .cleanup
        default: return nil
        }
    }

    /// Reads the file's header, and for GGUF its metadata, and checks that it is complete enough to load.
    public static func inspect(_ url: URL) throws -> ModelFormat {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ModelError.unreadable(url.lastPathComponent)
        }
        defer { try? handle.close() }
        var reader = FileReader(handle: handle)
        guard let magic = try? reader.bytes(4) else { throw ModelError.notAModel }
        switch magic {
        case whisperMagic:
            try checkWhisperHeader(&reader)
            return .whisper
        case ggufMagic:
            return .gguf(try readGGUF(&reader))
        default:
            throw ModelError.notAModel
        }
    }

    /// whisper.cpp's header is eleven 32-bit numbers. The tenth is the number of mel bands,
    /// which is 80 or 128 in every Whisper model. Old llama.cpp files share the magic but not this.
    private static func checkWhisperHeader(_ reader: inout FileReader) throws {
        var values: [UInt32] = []
        do {
            for _ in 0..<11 { values.append(try reader.u32()) }
        } catch {
            throw ModelError.damaged
        }
        guard values[9] == 80 || values[9] == 128 else { throw ModelError.notAModel }
    }

    // MARK: GGUF

    private enum ValueType: UInt32 {
        case uint8 = 0, int8, uint16, int16, uint32, int32, float32, bool, string, array, uint64, int64, float64

        /// The size in bytes of a value of this type, or nil when it varies.
        var size: UInt64? {
            switch self {
            case .uint8, .int8, .bool: return 1
            case .uint16, .int16: return 2
            case .uint32, .int32, .float32: return 4
            case .uint64, .int64, .float64: return 8
            case .string, .array: return nil
            }
        }
    }

    /// The most metadata entries Lucid will read. Real models have a few dozen.
    private static let maxEntries: UInt64 = 1_000_000

    private static func readGGUF(_ reader: inout FileReader) throws -> GGUFInfo {
        guard let version = try? reader.u32() else { throw ModelError.damaged }
        // Version 1 stored lengths in 32 bits, and llama.cpp dropped it long ago.
        guard version >= 2 else { throw ModelError.oldFormat }
        var info = GGUFInfo(version: version)
        // A later version may lay out its metadata differently, so leave it to llama.cpp to judge.
        guard version <= 3 else { return info }
        do {
            try readMetadata(&reader, into: &info)
        } catch {
            throw ModelError.damaged
        }
        return info
    }

    private struct Corrupt: Error {}

    private static func readMetadata(_ reader: inout FileReader, into info: inout GGUFInfo) throws {
        _ = try reader.u64()  // the number of tensors
        let entries = try reader.u64()
        guard entries <= maxEntries else { throw Corrupt() }
        var chatTemplate = false
        for _ in 0..<entries {
            let key = try reader.string(limit: 65_536)
            guard let type = ValueType(rawValue: try reader.u32()) else { throw Corrupt() }
            switch key {
            case "general.architecture":
                info.architecture = try readString(type, &reader)
            case "general.type":
                info.type = try readString(type, &reader)
            case "split.count":
                info.splitCount = try readInteger(type, &reader)
            case "tokenizer.chat_template":
                chatTemplate = true
                try skip(type, &reader, depth: 0)
            default:
                try skip(type, &reader, depth: 0)
            }
        }
        info.hasChatTemplate = chatTemplate
    }

    private static func readString(_ type: ValueType, _ reader: inout FileReader) throws -> String? {
        guard type == .string else {
            try skip(type, &reader, depth: 0)
            return nil
        }
        return try reader.string(limit: 65_536)
    }

    private static func readInteger(_ type: ValueType, _ reader: inout FileReader) throws -> Int {
        guard let size = type.size, type != .float32, type != .float64, type != .bool else { throw Corrupt() }
        let raw = try reader.unsigned(Int(size))
        // Keep the number in range, whatever the stored width. A split count is small in practice.
        return Int(min(raw, UInt64(Int32.max)))
    }

    private static func skip(_ type: ValueType, _ reader: inout FileReader, depth: Int) throws {
        if let size = type.size {
            try reader.skip(size)
            return
        }
        if type == .string {
            try reader.skip(try reader.u64())
            return
        }
        // An array: the element type, the count, then the elements. Arrays may nest.
        guard depth < 4, let element = ValueType(rawValue: try reader.u32()) else { throw Corrupt() }
        let count = try reader.u64()
        if let size = element.size {
            let (total, overflow) = count.multipliedReportingOverflow(by: size)
            guard !overflow else { throw Corrupt() }
            try reader.skip(total)
            return
        }
        guard count <= 50_000_000 else { throw Corrupt() }
        for _ in 0..<count { try skip(element, &reader, depth: depth + 1) }
    }
}

/// Buffered, forward-only reads from a file. Throws `FileReader.Ended` when the file ends early.
struct FileReader {
    struct Ended: Error {}

    private let handle: FileHandle
    /// Bytes read from the file and not yet used start at `position`.
    private var buffer = Data()
    private var position = 0
    private static let chunk = 1 << 20

    init(handle: FileHandle) {
        self.handle = handle
    }

    mutating func bytes(_ count: Int) throws -> Data {
        try fill(count)
        let taken = buffer.subdata(in: position..<(position + count))
        position += count
        return taken
    }

    /// Makes sure at least `count` unused bytes are buffered.
    private mutating func fill(_ count: Int) throws {
        guard buffer.count - position < count else { return }
        buffer = buffer.subdata(in: position..<buffer.count)
        position = 0
        while buffer.count < count {
            guard let more = try handle.read(upToCount: max(Self.chunk, count - buffer.count)), !more.isEmpty else {
                throw Ended()
            }
            buffer.append(more)
        }
    }

    /// Moves forward `count` bytes. Seeks past what is not buffered, after checking the file is long enough.
    mutating func skip(_ count: UInt64) throws {
        let buffered = UInt64(buffer.count - position)
        if count <= buffered {
            position += Int(count)
            return
        }
        let beyond = count - buffered
        buffer = Data()
        position = 0
        let (target, overflow) = try handle.offset().addingReportingOverflow(beyond)
        guard !overflow, target <= (try handle.seekToEnd()) else { throw Ended() }
        try handle.seek(toOffset: target)
    }

    /// A little-endian unsigned number `size` bytes wide.
    mutating func unsigned(_ size: Int) throws -> UInt64 {
        let data = try bytes(size)
        var value: UInt64 = 0
        for (index, byte) in data.enumerated() {
            value |= UInt64(byte) << (8 * UInt64(index))
        }
        return value
    }

    mutating func u32() throws -> UInt32 {
        UInt32(try unsigned(4))
    }

    mutating func u64() throws -> UInt64 {
        try unsigned(8)
    }

    /// A GGUF string: a 64-bit length, then that many bytes of UTF-8.
    mutating func string(limit: UInt64) throws -> String {
        let length = try u64()
        guard length <= limit else { throw Ended() }
        return String(decoding: try bytes(Int(length)), as: UTF8.self)
    }
}
