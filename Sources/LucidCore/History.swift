import Foundation

/// One past dictation. It keeps the original transcript, so nothing is ever lost to cleanup.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    /// The app the text was dictated into.
    public var appName: String
    public var bundleID: String?
    public var audioSeconds: Double
    /// Time spent on speech recognition, in milliseconds.
    public var speechMillis: Int
    /// Nil when the dictation failed before any text was produced.
    public var result: PipelineResult?
    /// Why the dictation failed, in words for the user.
    public var failure: String?
    /// The file name of the kept recording, inside the store's `recordings` folder.
    public var audioFile: String?

    public init(
        id: UUID = UUID(),
        date: Date,
        appName: String,
        bundleID: String?,
        audioSeconds: Double,
        speechMillis: Int,
        result: PipelineResult?,
        failure: String?,
        audioFile: String? = nil
    ) {
        self.id = id
        self.date = date
        self.appName = appName
        self.bundleID = bundleID
        self.audioSeconds = audioSeconds
        self.speechMillis = speechMillis
        self.result = result
        self.failure = failure
        self.audioFile = audioFile
    }
}

/// The record of past dictations, stored as `history.json` with a `recordings` folder beside it.
///
/// Not thread-safe. Use it from one thread.
public final class HistoryStore {
    /// Newest first.
    public private(set) var entries: [HistoryEntry] = []
    public var limit = 200
    /// How many of the newest entries keep their audio.
    public var audioLimit = 20
    public var audioMaxAge: TimeInterval = 7 * 86_400

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("history.json") }
    private var recordingsURL: URL { directory.appendingPathComponent("recordings") }

    public init(directory: URL) {
        self.directory = directory
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    /// Adds an entry at the front. Pass the recording as `wav` to keep it for a retry, or
    /// nil to keep no audio.
    @discardableResult
    public func add(_ entry: HistoryEntry, wav: Data?, now: Date = Date()) -> HistoryEntry {
        var saved = entry
        if let wav {
            let name = "\(entry.id.uuidString).wav"
            do {
                try FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
                try wav.write(to: recordingsURL.appendingPathComponent(name), options: .atomic)
                saved.audioFile = name
            } catch {
                saved.audioFile = nil
            }
        }
        entries.insert(saved, at: 0)
        prune(now: now)
        save()
        return entries.first { $0.id == saved.id } ?? saved
    }

    public func audioURL(for entry: HistoryEntry) -> URL? {
        guard let name = entry.audioFile else { return nil }
        let url = recordingsURL.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        deleteAudio(of: entries[index])
        entries.remove(at: index)
        save()
    }

    public func clear() {
        for entry in entries { deleteAudio(of: entry) }
        entries = []
        save()
    }

    /// Applies the limits: at most `limit` entries, audio for at most `audioLimit` of the
    /// newest, and no audio older than `audioMaxAge`.
    private func prune(now: Date) {
        if entries.count > limit {
            for entry in entries[limit...] { deleteAudio(of: entry) }
            entries.removeSubrange(limit...)
        }
        var kept = 0
        for index in entries.indices where entries[index].audioFile != nil {
            let tooOld = now.timeIntervalSince(entries[index].date) > audioMaxAge
            if kept >= audioLimit || tooOld {
                deleteAudio(of: entries[index])
                entries[index].audioFile = nil
            } else {
                kept += 1
            }
        }
    }

    private func deleteAudio(of entry: HistoryEntry) {
        guard let name = entry.audioFile else { return }
        try? FileManager.default.removeItem(at: recordingsURL.appendingPathComponent(name))
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            // History is a convenience. Failing to save it must never interrupt a dictation.
        }
    }
}
