import Foundation
import LucidCore
import LucidEngines

private func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lucid-models-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

/// The start of a whisper.cpp model file: the magic and the eleven header numbers.
func whisperHeader(mels: Int32 = 80) -> Data {
    var data = Data("lmgg".utf8)
    let header: [Int32] = [51866, 1500, 1280, 20, 32, 448, 1280, 20, 4, mels, 8]
    for value in header { data.append(littleEndian(value)) }
    data.append(Data(repeating: 0, count: 64))
    return data
}

func ggufString(_ text: String) -> Data {
    littleEndian(UInt64(text.utf8.count)) + Data(text.utf8)
}

/// One GGUF metadata value, for building test files. The numbers are GGUF's own type codes.
enum GGUFValue {
    case string(String)
    case uint16(UInt16)
    case uint32(UInt32)
    case strings([String])
    case floats(Int)

    var encoded: Data {
        switch self {
        case .string(let text): return littleEndian(UInt32(8)) + ggufString(text)
        case .uint16(let number): return littleEndian(UInt32(2)) + littleEndian(number)
        case .uint32(let number): return littleEndian(UInt32(4)) + littleEndian(number)
        case .strings(let items):
            return littleEndian(UInt32(9)) + littleEndian(UInt32(8)) + littleEndian(UInt64(items.count))
                + items.reduce(Data()) { $0 + ggufString($1) }
        case .floats(let count):
            return littleEndian(UInt32(9)) + littleEndian(UInt32(6)) + littleEndian(UInt64(count))
                + Data(repeating: 0, count: count * 4)
        }
    }
}

/// The start of a GGUF file with the given metadata, like the one llama.cpp writes.
func gguf(version: UInt32 = 3, _ entries: [(String, GGUFValue)]) -> Data {
    var data = Data("GGUF".utf8) + littleEndian(version) + littleEndian(UInt64(0)) + littleEndian(UInt64(entries.count))
    for (key, value) in entries { data += ggufString(key) + value.encoded }
    return data + Data(repeating: 0, count: 32)
}

/// A typical instruction model's metadata, with a long token list before the chat template.
func chatModel(architecture: String = "llama", extra: [(String, GGUFValue)] = []) -> Data {
    gguf([
        ("general.architecture", .string(architecture)),
        ("general.name", .string("Test Model")),
        ("llama.context_length", .uint32(8192)),
        ("tokenizer.ggml.tokens", .strings((0..<3000).map { "token\($0)" })),
        ("tokenizer.ggml.scores", .floats(3000)),
        ("tokenizer.chat_template", .string("{% for message in messages %}{{ message.content }}{% endfor %}")),
    ] + extra)
}

@discardableResult
private func write(_ data: Data, _ name: String, in folder: URL) -> URL {
    let url = folder.appendingPathComponent(name)
    try? data.write(to: url)
    return url
}

private func expectError(_ expected: ModelError, file: String = #fileID, line: Int = #line, _ body: () throws -> Void) {
    do {
        try body()
        expectTrue(false, "expected \(expected)", file: file, line: line)
    } catch let error as ModelError {
        expectEqual(error, expected, file: file, line: line)
    } catch {
        expectTrue(false, "unexpected error \(error)", file: file, line: line)
    }
}

func modelLibraryTests() {
    suite("Model files") {
        test("recognises a Whisper model") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = write(whisperHeader(), "ggml-small.en.bin", in: folder)
            expectEqual(try ModelFile.inspect(url), .whisper)
            expectEqual(ModelFile.kind(of: url), .speech)
        }

        test("rejects a file with the Whisper magic but not a Whisper header") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = write(whisperHeader(mels: 4096), "old-llama.bin", in: folder)
            expectError(.notAModel) { _ = try ModelFile.inspect(url) }
        }

        test("reads the metadata of a GGUF model past a long token list") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = write(chatModel(), "model.gguf", in: folder)
            expectEqual(
                try ModelFile.inspect(url),
                .gguf(GGUFInfo(version: 3, architecture: "llama", splitCount: 1, hasChatTemplate: true))
            )
            expectEqual(ModelFile.kind(of: url), .cleanup)
        }

        test("notices a GGUF model with no chat template") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = write(gguf([("general.architecture", .string("llama"))]), "base.gguf", in: folder)
            expectEqual(try ModelFile.inspect(url), .gguf(GGUFInfo(version: 3, architecture: "llama", hasChatTemplate: false)))
        }

        test("rejects files that are not models") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let text = write(Data("hello, this is a text file".utf8), "notes.gguf", in: folder)
            let empty = write(Data(), "empty.bin", in: folder)
            expectError(.notAModel) { _ = try ModelFile.inspect(text) }
            expectError(.notAModel) { _ = try ModelFile.inspect(empty) }
            expectEqual(ModelFile.kind(of: text), nil)
            expectError(.unreadable("missing.gguf")) { _ = try ModelFile.inspect(folder.appendingPathComponent("missing.gguf")) }
        }

        test("rejects a GGUF file cut off in its metadata") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let whole = chatModel()
            let url = write(whole.prefix(whole.count / 2), "partial.gguf", in: folder)
            expectError(.damaged) { _ = try ModelFile.inspect(url) }
        }

        test("rejects GGUF version 1") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = write(gguf(version: 1, []), "ancient.gguf", in: folder)
            expectError(.oldFormat) { _ = try ModelFile.inspect(url) }
        }
    }

    suite("Model library") {
        test("lists built-in and added models, and skips everything else") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            write(whisperHeader(), "ggml-large-v3-turbo-q5_0.bin", in: folder)
            write(chatModel(), "s1-mini-q4_k_m.gguf", in: folder)
            write(chatModel(), "Llama-3.2-3B-Instruct-Q4_K_M.gguf", in: folder)
            write(whisperHeader(), "ggml-small.en.bin", in: folder)
            write(chatModel(), "downloading.gguf.part", in: folder)
            write(Data("not a model".utf8), "readme.txt", in: folder)
            write(chatModel(), ".hidden.gguf", in: folder)

            let models = ModelLibrary(directory: folder).models()
            expectEqual(models.map(\.fileName), [
                "ggml-large-v3-turbo-q5_0.bin",
                "s1-mini-q4_k_m.gguf",
                "ggml-small.en.bin",
                "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            ])
            expectEqual(models.map(\.kind), [.speech, .cleanup, .speech, .cleanup])
            expectEqual(models.map(\.isBuiltIn), [true, true, false, false])
            expectEqual(models[1].name, "S1-mini by Superwhisper")
            expectEqual(models[1].style, .s1)
            expectEqual(models[2].style, nil)
            expectEqual(models[3].name, "Llama-3.2-3B-Instruct-Q4_K_M")
            expectEqual(models[3].style, .general)
            expectTrue(models[3].bytes > 1000, "size \(models[3].bytes)")
        }

        test("an empty or missing folder has no models") {
            let missing = FileManager.default.temporaryDirectory.appendingPathComponent("lucid-none-\(UUID().uuidString)")
            expectEqual(ModelLibrary(directory: missing).models(), [])
        }

        test("adds a model by copying it, and leaves the original") {
            let source = temporaryFolder()
            let models = temporaryFolder()
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: models)
            }
            let original = write(chatModel(), "Phi-4-mini-instruct-Q4_K_M.gguf", in: source)
            let library = ModelLibrary(directory: models.appendingPathComponent("new-folder"))

            let added = try library.add(from: original, as: .cleanup)
            expectEqual(added.model.fileName, "Phi-4-mini-instruct-Q4_K_M.gguf")
            expectEqual(added.model.kind, .cleanup)
            expectEqual(added.model.style, .general)
            expectFalse(added.model.isBuiltIn)
            expectEqual(added.warning, nil)
            expectTrue(FileManager.default.fileExists(atPath: original.path), "the original was moved")
            expectEqual(library.models().map(\.fileName), ["Phi-4-mini-instruct-Q4_K_M.gguf"])
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: library.directory.path)
            expectFalse(leftovers.contains { $0.hasSuffix(".part") }, "\(leftovers)")
        }

        test("adds a speech model, and works out the kind when none is given") {
            let source = temporaryFolder()
            let models = temporaryFolder()
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: models)
            }
            let original = write(whisperHeader(), "ggml-small.en.bin", in: source)
            let added = try ModelLibrary(directory: models).add(from: original)
            expectEqual(added.model.kind, .speech)
            expectEqual(added.model.style, nil)
            expectEqual(added.model.name, "ggml-small.en")
        }

        test("suggests the S1-mini format for another copy of S1-mini") {
            let source = temporaryFolder()
            let models = temporaryFolder()
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: models)
            }
            let original = write(chatModel(), "s1-mini-q8_0.gguf", in: source)
            let library = ModelLibrary(directory: models)
            expectEqual(try library.add(from: original).model.style, .s1)
            expectEqual(library.style(of: "s1-mini-q8_0.gguf"), .s1)
        }

        test("adds a built-in model downloaded by hand") {
            let source = temporaryFolder()
            let models = temporaryFolder()
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: models)
            }
            let original = write(chatModel(), "s1-mini-q4_k_m.gguf", in: source)
            let added = try ModelLibrary(directory: models).add(from: original, as: .cleanup)
            expectTrue(added.model.isBuiltIn)
            expectEqual(added.model.name, "S1-mini by Superwhisper")
            expectEqual(added.model.style, .s1)
        }

        test("refuses the wrong kind, add-ons, split models and duplicates") {
            let source = temporaryFolder()
            let models = temporaryFolder()
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: models)
            }
            let library = ModelLibrary(directory: models)
            let speech = write(whisperHeader(), "ggml-base.bin", in: source)
            let cleanup = write(chatModel(), "model.gguf", in: source)
            let vision = write(chatModel(architecture: "clip"), "mmproj-F16.gguf", in: source)
            let projector = write(chatModel(extra: [("general.type", .string("mmproj"))]), "mmproj-2.gguf", in: source)
            let adapter = write(chatModel(extra: [("general.type", .string("adapter"))]), "lora.gguf", in: source)
            let split = write(chatModel(extra: [("split.count", .uint16(3))]), "big-00001-of-00003.gguf", in: source)
            let partial = write(chatModel(), "model.gguf.part", in: source)

            expectError(.wrongKind(.speech)) { _ = try library.add(from: speech, as: .cleanup) }
            expectError(.wrongKind(.cleanup)) { _ = try library.add(from: cleanup, as: .speech) }
            expectError(.notStandalone("a vision add-on (mmproj)")) { _ = try library.add(from: vision) }
            expectError(.notStandalone("a vision add-on (mmproj)")) { _ = try library.add(from: projector) }
            expectError(.notStandalone("an adapter (LoRA)")) { _ = try library.add(from: adapter) }
            expectError(.split(3)) { _ = try library.add(from: split) }
            expectError(.damaged) { _ = try library.add(from: partial) }
            expectEqual(library.models(), [])

            _ = try library.add(from: cleanup)
            expectError(.alreadyInstalled("model.gguf")) { _ = try library.add(from: cleanup) }
        }

        test("warns about a model with no chat template") {
            let source = temporaryFolder()
            let models = temporaryFolder()
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: models)
            }
            let base = write(gguf([("general.architecture", .string("llama"))]), "base.gguf", in: source)
            let added = try ModelLibrary(directory: models).add(from: base)
            expectTrue(added.warning?.contains("no chat template") == true, "\(String(describing: added.warning))")
        }

        test("keeps the prompt format of an added model") {
            let source = temporaryFolder()
            let models = temporaryFolder()
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: models)
            }
            let original = write(chatModel(), "my-cleaner.gguf", in: source)
            _ = try ModelLibrary(directory: models).add(from: original, style: .general)
            try ModelLibrary(directory: models).setStyle(.s1, for: "my-cleaner.gguf")
            let reopened = ModelLibrary(directory: models)
            expectEqual(reopened.models().first?.style, .s1)
            expectEqual(reopened.style(of: "my-cleaner.gguf"), .s1)
            expectEqual(reopened.style(of: EngineConfig.general.fileName), .general)
            expectEqual(reopened.style(of: "not-here.gguf"), nil)
            expectError(.builtIn("S1-mini by Superwhisper")) { try reopened.setStyle(.general, for: "s1-mini-q4_k_m.gguf") }
        }

        test("deletes any model, Lucid's own included, and says how much space it freed") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let builtIn = chatModel()
            write(builtIn, "s1-mini-q4_k_m.gguf", in: folder)
            let source = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: source) }
            let library = ModelLibrary(directory: folder)
            _ = try library.add(from: write(chatModel(), "mine.gguf", in: source), style: .s1)

            try library.remove("mine.gguf")
            expectEqual(library.models().map(\.fileName), ["s1-mini-q4_k_m.gguf"])
            expectEqual(library.style(of: "mine.gguf"), nil)
            expectEqual(try library.remove("s1-mini-q4_k_m.gguf"), Int64(builtIn.count))
            expectEqual(library.models(), [])
            expectError(.notFound("mine.gguf")) { try library.remove("mine.gguf") }
            expectError(.notFound("models.json")) { try library.remove("models.json") }
            expectError(.notFound("../outside.gguf")) { try library.remove("../outside.gguf") }
        }

        test("deletes a link, never the model it points to") {
            let folder = temporaryFolder()
            let elsewhere = temporaryFolder()
            defer {
                try? FileManager.default.removeItem(at: folder)
                try? FileManager.default.removeItem(at: elsewhere)
            }
            let target = write(chatModel(), "kept.gguf", in: elsewhere)
            try FileManager.default.createSymbolicLink(
                at: folder.appendingPathComponent("linked.gguf"), withDestinationURL: target
            )
            let library = ModelLibrary(directory: folder)
            expectEqual(library.models().map(\.fileName), ["linked.gguf"])
            try library.remove("linked.gguf")
            expectEqual(library.models(), [])
            expectTrue(FileManager.default.fileExists(atPath: target.path), "the linked model was deleted")
        }

        test("lists and discards unfinished downloads") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            write(Data(repeating: 1, count: 300), "big-model.gguf.part", in: folder)
            write(Data(repeating: 1, count: 100), "ggml-small.en.bin.part", in: folder)
            write(Data(repeating: 1, count: 50), "copying.gguf.copy.part", in: folder)
            write(Data(), "empty.gguf.part", in: folder)
            let library = ModelLibrary(directory: folder)
            expectEqual(library.partialDownloads(), [
                PartialDownload(fileName: "big-model.gguf", bytes: 300),
                PartialDownload(fileName: "ggml-small.en.bin", bytes: 100),
            ])
            try library.discardPartial(of: "big-model.gguf")
            expectEqual(library.partialDownloads().map(\.fileName), ["ggml-small.en.bin"])
            expectError(.notFound("big-model.gguf")) { try library.discardPartial(of: "big-model.gguf") }
            expectError(.notFound("../ggml-small.en.bin")) { try library.discardPartial(of: "../ggml-small.en.bin") }
        }
    }

    suite("Model choices") {
        let whisper = InstalledModel(fileName: EngineConfig.defaultSpeechModel, kind: .speech, name: "Whisper", style: nil, isBuiltIn: true, bytes: 1)
        let small = InstalledModel(fileName: "ggml-small.en.bin", kind: .speech, name: "ggml-small.en", style: nil, isBuiltIn: false, bytes: 1)
        let s1 = InstalledModel(fileName: EngineConfig.s1Mini.fileName, kind: .cleanup, name: "S1", style: .s1, isBuiltIn: true, bytes: 1)
        let qwen = InstalledModel(fileName: EngineConfig.general.fileName, kind: .cleanup, name: "Qwen", style: .general, isBuiltIn: true, bytes: 1)
        let llama = InstalledModel(fileName: "llama.gguf", kind: .cleanup, name: "llama", style: .general, isBuiltIn: false, bytes: 1)
        let s1Copy = InstalledModel(fileName: "s1-mini-q8_0.gguf", kind: .cleanup, name: "s1 copy", style: .s1, isBuiltIn: false, bytes: 1)

        test("with no choices, uses the built-in models") {
            let plan = ModelLibrary.plan(for: ModelChoices(), installed: [whisper, s1, qwen])
            expectEqual(plan.speech, EngineConfig.defaultSpeechModel)
            expectEqual(plan.light, EngineConfig.s1Mini)
            expectEqual(plan.medium, EngineConfig.general)
            expectEqual(plan.cleanup(for: .medium), EngineConfig.general)
            expectEqual(plan.cleanup(for: .off), EngineConfig.s1Mini)
        }

        test("uses the models the user chose") {
            let choices = ModelChoices(speech: "ggml-small.en.bin", light: "s1-mini-q8_0.gguf", medium: "llama.gguf")
            let plan = ModelLibrary.plan(for: choices, installed: [whisper, small, s1, s1Copy, llama])
            expectEqual(plan.speech, "ggml-small.en.bin")
            expectEqual(plan.light, CleanupModel(fileName: "s1-mini-q8_0.gguf", style: .s1))
            expectEqual(plan.medium, CleanupModel(fileName: "llama.gguf", style: .general))
            expectEqual(EngineConfig.standard(plan: plan, level: .light).cleanupModelURL.lastPathComponent, "s1-mini-q8_0.gguf")
            expectEqual(EngineConfig.standard(plan: plan, level: .medium).cleanupModel.style, .general)
            expectEqual(EngineConfig.standard(plan: plan, level: .medium).speechModelURL.lastPathComponent, "ggml-small.en.bin")
        }

        test("falls back to the built-in model when a chosen one is gone or the wrong kind") {
            let choices = ModelChoices(speech: "llama.gguf", light: "deleted.gguf", medium: "deleted.gguf")
            let plan = ModelLibrary.plan(for: choices, installed: [whisper, s1, qwen, llama])
            expectEqual(plan.speech, EngineConfig.defaultSpeechModel)
            expectEqual(plan.light, EngineConfig.s1Mini)
            expectEqual(plan.medium, EngineConfig.general)
        }

        test("Medium needs a model that uses Lucid's prompt") {
            let plan = ModelLibrary.plan(for: ModelChoices(medium: "s1-mini-q8_0.gguf"), installed: [whisper, s1, s1Copy])
            expectEqual(plan.medium, nil)
            expectEqual(plan.cleanup(for: .medium), EngineConfig.s1Mini)
        }

        test("uses another installed model when Lucid's own is gone too") {
            let plan = ModelLibrary.plan(for: ModelChoices(speech: "deleted.bin"), installed: [small, qwen])
            expectEqual(plan.speech, "ggml-small.en.bin")
            expectEqual(plan.light, EngineConfig.general)
            let none = ModelLibrary.plan(for: ModelChoices(), installed: [])
            expectEqual(none.speech, EngineConfig.defaultSpeechModel)
            expectEqual(none.light, EngineConfig.s1Mini)
        }

        test("says what deleting a model changes") {
            let installed = [whisper, small, s1, qwen, llama]
            let choices = ModelChoices(speech: "ggml-small.en.bin", medium: "llama.gguf")
            expectEqual(
                ModelLibrary.effectsOfRemoving("ggml-small.en.bin", choices: choices, installed: installed),
                RemovalEffects(speech: .switches(to: EngineConfig.defaultSpeechModel))
            )
            expectEqual(
                ModelLibrary.effectsOfRemoving("llama.gguf", choices: choices, installed: installed),
                RemovalEffects(medium: .switches(to: EngineConfig.general.fileName))
            )
            expectTrue(ModelLibrary.effectsOfRemoving(EngineConfig.defaultSpeechModel, choices: choices, installed: installed).isEmpty)
            expectEqual(
                ModelLibrary.effectsOfRemoving(EngineConfig.s1Mini.fileName, choices: ModelChoices(), installed: [whisper, s1]),
                RemovalEffects(light: .nothingLeft)
            )
            expectEqual(
                ModelLibrary.effectsOfRemoving(EngineConfig.general.fileName, choices: ModelChoices(), installed: [whisper, qwen]),
                RemovalEffects(light: .nothingLeft, medium: .nothingLeft)
            )
            expectEqual(
                ModelLibrary.effectsOfRemoving(EngineConfig.defaultSpeechModel, choices: ModelChoices(), installed: [whisper, s1]),
                RemovalEffects(speech: .nothingLeft)
            )
        }

        test("forgetting a model clears every choice of it") {
            var choices = ModelChoices(speech: "a.bin", light: "b.gguf", medium: "b.gguf")
            choices.forget("b.gguf")
            expectEqual(choices, ModelChoices(speech: "a.bin"))
        }
    }
}
