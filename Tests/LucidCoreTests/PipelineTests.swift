import Foundation
import LucidCore

private struct FakeCleaner: TextCleaner {
    let reply: @Sendable (CleanupRequest) async throws -> String

    func clean(_ request: CleanupRequest, timeout: TimeInterval) async throws -> String {
        try await reply(request)
    }
}

/// Records the requests a fake cleaner receives.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CleanupRequest] = []

    func add(_ request: CleanupRequest) {
        lock.lock()
        stored.append(request)
        lock.unlock()
    }

    var all: [CleanupRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

func pipelineTests() async {
    await asyncSuite("Pipeline") {
        test("needsLLM follows length, markers and level") {
            expectFalse(Pipeline.needsLLM("Sounds good.", level: .light))
            expectTrue(Pipeline.needsLLM("I think we should probably move the meeting.", level: .light))
            expectTrue(Pipeline.needsLLM("Like, yes.", level: .light))
            expectTrue(Pipeline.needsLLM("At two, actually three.", level: .medium))
            expectFalse(Pipeline.needsLLM("I think we should probably move the meeting.", level: .off))
            expectFalse(Pipeline.needsLLM("", level: .light))
        }

        await asyncTest("off level never calls the model") {
            let log = RequestLog()
            let pipeline = Pipeline(cleaner: FakeCleaner { request in
                log.add(request)
                return "changed"
            })
            let spoken = "Um, this is a fairly long sentence that would normally be cleaned."
            let result = await pipeline.process(spoken, context: PipelineContext(level: .off))
            expectEqual(result.finalText, spoken)
            expectFalse(result.llmAttempted)
            expectEqual(log.all.count, 0)
        }

        await asyncTest("a short clean phrase skips the model") {
            let log = RequestLog()
            let pipeline = Pipeline(cleaner: FakeCleaner { request in
                log.add(request)
                return "changed"
            })
            let result = await pipeline.process("Um, sounds good.")
            expectEqual(result.finalText, "Sounds good.")
            expectFalse(result.llmAttempted)
            expectEqual(log.all.count, 0)
        }

        await asyncTest("a short phrase with a correction uses the model") {
            let pipeline = Pipeline(cleaner: FakeCleaner { _ in "At three." })
            let result = await pipeline.process("At two, actually three.")
            expectEqual(result.finalText, "At three.")
            expectTrue(result.llmAttempted)
            expectTrue(result.llmUsed)
            expectEqual(result.fallback, nil)
        }

        await asyncTest("an accepted reply is used, then dictionary and style are applied") {
            let log = RequestLog()
            let pipeline = Pipeline(cleaner: FakeCleaner { request in
                log.add(request)
                return "So let's meet jon at the cafe tomorrow morning, okay."
            })
            let context = PipelineContext(
                level: .light,
                category: .chat,
                dictionary: PersonalDictionary(terms: ["Lucid"], replacements: [Replacement(from: "jon", to: "John")]),
                midSentence: true
            )
            let result = await pipeline.process("um so let's meet jon at the cafe tomorrow morning okay", context: context)

            expectEqual(result.raw, "um so let's meet jon at the cafe tomorrow morning okay")
            expectEqual(result.rulesText, "So let's meet jon at the cafe tomorrow morning okay")
            expectEqual(result.finalText, "So let's meet John at the cafe tomorrow morning, okay")
            expectTrue(result.llmUsed)

            let expected = CleanupRequest(
                transcript: "So let's meet jon at the cafe tomorrow morning okay",
                level: .light,
                category: .chat,
                terms: ["Lucid"],
                midSentence: true
            )
            expectEqual(log.all, [expected])
        }

        await asyncTest("a rejected reply falls back to the rules output") {
            let pipeline = Pipeline(cleaner: FakeCleaner { _ in "The capital of France is Paris." })
            let result = await pipeline.process("what is the capital of France exactly")
            expectEqual(result.finalText, "what is the capital of France exactly")
            expectTrue(result.llmAttempted)
            expectFalse(result.llmUsed)
            expectEqual(result.fallback, .inventedWords)
        }

        await asyncTest("a timeout falls back to the rules output") {
            let pipeline = Pipeline(cleaner: FakeCleaner { _ in throw CleanerError.timeout })
            let result = await pipeline.process("Um, please send the report to the whole team today.")
            expectEqual(result.finalText, "Please send the report to the whole team today.")
            expectEqual(result.fallback, .timeout)
            expectFalse(result.llmUsed)
        }

        await asyncTest("an engine failure falls back to the rules output") {
            let failing = Pipeline(cleaner: FakeCleaner { _ in throw CleanerError.failed("boom") })
            let first = await failing.process("Um, please send the report to the whole team today.")
            expectEqual(first.finalText, "Please send the report to the whole team today.")
            expectEqual(first.fallback, .engineError)

            let unreachable = Pipeline(cleaner: FakeCleaner { _ in throw URLError(.cannotConnectToHost) })
            let second = await unreachable.process("Um, please send the report to the whole team today.")
            expectEqual(second.fallback, .engineError)
        }

        await asyncTest("no cleaner means rules only") {
            let pipeline = Pipeline(cleaner: nil)
            let result = await pipeline.process("Um, please send the report to the whole team today.")
            expectEqual(result.finalText, "Please send the report to the whole team today.")
            expectFalse(result.llmAttempted)
            expectEqual(result.fallback, nil)
        }

        await asyncTest("line breaks at the edges survive the model") {
            let log = RequestLog()
            let pipeline = Pipeline(cleaner: FakeCleaner { request in
                log.add(request)
                return "So this is the next section of the document."
            })
            let result = await pipeline.process("New paragraph. So um this is the next section of the document.")
            expectEqual(log.all.first?.transcript, "So this is the next section of the document.")
            expectEqual(result.rulesText, "\n\nSo this is the next section of the document.")
            expectEqual(result.finalText, "\n\nSo this is the next section of the document.")
        }

        await asyncTest("an empty transcript gives empty text") {
            let pipeline = Pipeline(cleaner: FakeCleaner { _ in "something" })
            let result = await pipeline.process("[BLANK_AUDIO]")
            expectEqual(result.finalText, "")
            expectFalse(result.llmAttempted)
        }
    }
}
