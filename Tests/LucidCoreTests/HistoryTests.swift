import Foundation
import LucidCore

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lucid-history-\(UUID().uuidString)")
}

private func result(_ text: String) -> PipelineResult {
    PipelineResult(
        raw: "um " + text,
        rulesText: text,
        finalText: text,
        llmAttempted: false,
        llmUsed: false,
        fallback: nil,
        rejectedReply: nil,
        cleanMillis: 5
    )
}

private func entry(_ text: String, at seconds: TimeInterval) -> HistoryEntry {
    HistoryEntry(
        date: Date(timeIntervalSince1970: seconds),
        appName: "Notes",
        bundleID: "com.apple.Notes",
        audioSeconds: 2.5,
        speechMillis: 500,
        result: result(text),
        failure: nil
    )
}

func historyTests() {
    suite("History") {
        test("keeps entries newest first and reloads them") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = HistoryStore(directory: folder)
            expectEqual(store.entries, [])
            let first = store.add(entry("first", at: 1_000), wav: nil)
            let second = store.add(entry("second", at: 2_000), wav: nil)
            expectEqual(store.entries.map(\.id), [second.id, first.id])

            let reloaded = HistoryStore(directory: folder)
            expectEqual(reloaded.entries, store.entries)
            expectEqual(reloaded.entries.first?.result?.finalText, "second")
            expectEqual(reloaded.entries.first?.result?.raw, "um second")
        }

        test("trims to the limit") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = HistoryStore(directory: folder)
            store.limit = 3
            for index in 0..<5 { store.add(entry("item \(index)", at: Double(index)), wav: nil) }
            expectEqual(store.entries.compactMap { $0.result?.finalText }, ["item 4", "item 3", "item 2"])
        }

        test("keeps audio only for the newest recordings") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = HistoryStore(directory: folder)
            store.audioLimit = 2
            let now = Date(timeIntervalSince1970: 10_000)
            for index in 0..<4 {
                store.add(entry("item \(index)", at: 10_000 + Double(index)), wav: Data([UInt8(index)]), now: now)
            }
            let withAudio = store.entries.filter { store.audioURL(for: $0) != nil }
            expectEqual(withAudio.compactMap { $0.result?.finalText }, ["item 3", "item 2"])
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("recordings").path)
            expectEqual(files.count, 2)
            if let url = store.audioURL(for: store.entries[0]) {
                expectEqual(try Data(contentsOf: url), Data([3]))
            } else {
                expectTrue(false, "the newest entry should have audio")
            }
        }

        test("drops audio older than the maximum age") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = HistoryStore(directory: folder)
            let day: TimeInterval = 86_400
            let old = store.add(entry("old", at: 0), wav: Data([1]), now: Date(timeIntervalSince1970: 0))
            expectTrue(store.audioURL(for: old) != nil)
            store.add(entry("new", at: 8 * day), wav: Data([2]), now: Date(timeIntervalSince1970: 8 * day))
            let oldEntry = store.entries.first { $0.id == old.id }
            expectEqual(oldEntry?.audioFile, nil)
            expectEqual(store.entries.count, 2)
        }

        test("stores no audio when none is given") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = HistoryStore(directory: folder)
            let saved = store.add(entry("quiet", at: 1), wav: nil)
            expectEqual(saved.audioFile, nil)
            expectEqual(store.audioURL(for: saved), nil)
        }

        test("records a failed dictation with its audio") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = HistoryStore(directory: folder)
            let failed = HistoryEntry(
                date: Date(timeIntervalSince1970: 5),
                appName: "Mail",
                bundleID: "com.apple.mail",
                audioSeconds: 4,
                speechMillis: 0,
                result: nil,
                failure: "The speech engine is not running."
            )
            let saved = store.add(failed, wav: Data([9]), now: Date(timeIntervalSince1970: 5))
            expectTrue(store.audioURL(for: saved) != nil)
            let reloaded = HistoryStore(directory: folder)
            expectEqual(reloaded.entries.first?.failure, "The speech engine is not running.")
            expectEqual(reloaded.entries.first?.result, nil)
        }

        test("remove and clear delete audio too") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = HistoryStore(directory: folder)
            let now = Date(timeIntervalSince1970: 100)
            let first = store.add(entry("first", at: 100), wav: Data([1]), now: now)
            store.add(entry("second", at: 101), wav: Data([2]), now: now)
            let recordings = folder.appendingPathComponent("recordings").path

            store.remove(first.id)
            expectEqual(store.entries.count, 1)
            expectEqual(try FileManager.default.contentsOfDirectory(atPath: recordings).count, 1)

            store.clear()
            expectEqual(store.entries, [])
            expectEqual(try FileManager.default.contentsOfDirectory(atPath: recordings).count, 0)
            expectEqual(HistoryStore(directory: folder).entries, [])
        }
    }
}
