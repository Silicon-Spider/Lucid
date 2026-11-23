import Foundation
import LucidCore
import LucidEngines

struct CLIError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Command-line arguments split into positional values, `--name value` options and `--name` flags.
struct Arguments {
    private(set) var positional: [String] = []
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    static let flagNames: Set<String> = ["rules-only", "verbose", "json", "mid-sentence", "help"]

    init(_ raw: [String]) throws {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--"), token.count > 2 {
                let name = String(token.dropFirst(2))
                if Self.flagNames.contains(name) {
                    flags.insert(name)
                } else {
                    guard index + 1 < raw.count else { throw CLIError("--\(name) needs a value") }
                    options[name] = raw[index + 1]
                    index += 1
                }
            } else {
                positional.append(token)
            }
            index += 1
        }
    }

    func option(_ name: String) -> String? { options[name] }
    func flag(_ name: String) -> Bool { flags.contains(name) }
}

let usage = """
lucid-cli: command-line access to Lucid's dictation pipeline

  lucid-cli doctor                      check that the engines and models are installed
  lucid-cli models                      list the models in Lucid's models folder
  lucid-cli add-model [--style s1|general] <file>
                                        copy a speech (.bin) or cleanup (.gguf) model into it
  lucid-cli clean [options] <text>      clean up a transcript given as text
  lucid-cli transcribe <file.wav>...    speech to text only
  lucid-cli dictate [options] <file.wav>...
                                        speech to clean text, with timings
  lucid-cli eval [options]              run the cleanup test set

Audio files must be 16 kHz mono 16-bit WAV.

Options:
  --level off|light|medium     cleanup level (default light)
  --category email|chat|code|other
  --app <bundle id>            choose the category from an app's bundle identifier
  --mid-sentence               the text continues an existing sentence
  --model s1|general|<file>    cleanup model: S1-mini by Superwhisper (default), the general
                               model, or a .gguf file name in the models folder
  --style s1|general           prompt format for a model given by file name (default: the
                               format set for it in Lucid, otherwise general)
  --speech-model <file>        speech model: a file name in the models folder
  --rules-only                 skip the cleanup model
  --json                       clean, dictate: print the full result as JSON
  --cases <file>               eval: the test set (default evals/cases.json)
  --group <name>               eval: run one group only
  --verbose                    eval: print every case, not only the failures
"""

// MARK: Shared set-up

func pipelineContext(_ arguments: Arguments) throws -> PipelineContext {
    var context = PipelineContext()
    if let value = arguments.option("level") {
        guard let level = CleanupLevel(rawValue: value) else {
            throw CLIError("unknown level '\(value)'. Use off, light or medium.")
        }
        context.level = level
    }
    if let value = arguments.option("category") {
        guard let category = AppCategory(rawValue: value) else {
            throw CLIError("unknown category '\(value)'. Use email, chat, code or other.")
        }
        context.category = category
    } else if let app = arguments.option("app") {
        context.category = AppCategory.forBundleID(app)
    }
    context.midSentence = arguments.flag("mid-sentence")
    let dictionaryURL = EngineConfig.supportDirectory.appendingPathComponent("dictionary.json")
    context.dictionary = (try? PersonalDictionary.load(from: dictionaryURL)) ?? .empty
    return context
}

func promptStyle(_ arguments: Arguments) throws -> PromptStyle? {
    guard let name = arguments.option("style") else { return nil }
    guard let style = PromptStyle(rawValue: name) else {
        throw CLIError("unknown style '\(name)'. Use s1 or general.")
    }
    return style
}

func engineConfig(_ arguments: Arguments) throws -> EngineConfig {
    let choice = arguments.option("model") ?? "s1"
    let cleanup: CleanupModel
    switch choice {
    case "s1":
        cleanup = EngineConfig.s1Mini
    case "general":
        cleanup = EngineConfig.general
    default:
        guard choice.hasSuffix(".gguf") else {
            throw CLIError("unknown model '\(choice)'. Use s1, general or a .gguf file name.")
        }
        let style = try promptStyle(arguments) ?? ModelLibrary.standard.style(of: choice) ?? .general
        cleanup = CleanupModel(fileName: choice, style: style)
    }
    let speech = arguments.option("speech-model") ?? EngineConfig.defaultSpeechModel
    return .standard(speech: speech, cleanup: cleanup)
}

func seconds(_ interval: TimeInterval) -> String {
    String(format: "%.2f s", interval)
}

func outcome(of result: PipelineResult) -> String {
    if result.llmUsed { return "cleanup model used" }
    if let fallback = result.fallback { return "rules only: the model's reply was not usable (\(fallback.rawValue))" }
    return "rules only"
}

func printJSON(_ result: PipelineResult) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(result), as: UTF8.self))
}

// MARK: Commands

func runDoctor(_ arguments: Arguments) throws -> Int32 {
    let config = try engineConfig(arguments)
    print("Speech engine:   \(config.whisperServer.path)")
    print("Cleanup engine:  \(config.llamaServer.path)")
    print("Speech model:    \(config.speechModelURL.path)")
    print("Cleanup model:   \(config.cleanupModelURL.path)")
    print("Engine logs:     \(config.logsDirectory.path)")
    let missing = config.missing()
    if missing.isEmpty {
        print("\nEverything is installed.")
        return 0
    }
    print("\nNot installed:")
    for item in missing { print("  - \(item)") }
    print("\nRun scripts/setup.sh to install what is missing.")
    return 1
}

func runModels() -> Int32 {
    let library = ModelLibrary.standard
    let models = library.models()
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    for kind in ModelKind.allCases {
        print(kind == .speech ? "Speech models" : "Cleanup models")
        let matching = models.filter { $0.kind == kind }
        if matching.isEmpty { print("  none") }
        for model in matching {
            var notes = [formatter.string(fromByteCount: model.bytes)]
            if model.isBuiltIn { notes.append("built in") }
            if let style = model.style { notes.append("\(style.rawValue) prompt") }
            print("  \(model.fileName)  (\(notes.joined(separator: ", ")))")
        }
        print("")
    }
    print("Folder: \(library.directory.path)")
    return 0
}

func runAddModel(_ arguments: Arguments) throws -> Int32 {
    guard arguments.positional.count == 1, let path = arguments.positional.first else {
        throw CLIError("add-model needs one model file")
    }
    let added = try ModelLibrary.standard.add(from: URL(fileURLWithPath: path), style: try promptStyle(arguments))
    let model = added.model
    if model.kind == .speech {
        print("Added \(model.fileName) as a speech model.")
        print("Try it with: lucid-cli dictate --speech-model \(model.fileName) <file.wav>")
    } else {
        print("Added \(model.fileName) as a cleanup model, using the \(model.style?.rawValue ?? "general") prompt.")
        print("Try it with: lucid-cli eval --model \(model.fileName)")
    }
    if let warning = added.warning { print("Note: \(warning)") }
    print("Choose it for the app in Lucid's Settings, Models.")
    return 0
}

func runClean(_ arguments: Arguments) async throws -> Int32 {
    let text = arguments.positional.joined(separator: " ")
    guard !text.isEmpty else { throw CLIError("clean needs some text") }
    let context = try pipelineContext(arguments)
    let supervisor = EngineSupervisor(config: try engineConfig(arguments), tracksProcesses: false)

    var cleaner: LlamaClient?
    if !arguments.flag("rules-only"), context.level != .off {
        try await supervisor.start(speech: false, cleanup: true)
        cleaner = try await supervisor.cleaner()
    }
    let result = await Pipeline(cleaner: cleaner).process(text, context: context)
    await supervisor.stop()

    if arguments.flag("json") {
        try printJSON(result)
    } else {
        print(result.finalText)
    }
    return 0
}

func runDictate(_ arguments: Arguments, transcribeOnly: Bool) async throws -> Int32 {
    guard !arguments.positional.isEmpty else { throw CLIError("give at least one WAV file") }
    let context = try pipelineContext(arguments)
    let useCleaner = !transcribeOnly && !arguments.flag("rules-only") && context.level != .off
    let supervisor = EngineSupervisor(config: try engineConfig(arguments), tracksProcesses: false)

    let startUp = Date()
    try await supervisor.start(speech: true, cleanup: useCleaner)
    let transcriber = try await supervisor.transcriber()
    let cleaner: LlamaClient? = useCleaner ? try await supervisor.cleaner() : nil
    let pipeline = Pipeline(cleaner: cleaner)
    if !transcribeOnly, !arguments.flag("json") {
        print("engines ready in \(seconds(Date().timeIntervalSince(startUp)))\n")
    }

    var status: Int32 = 0
    for path in arguments.positional {
        do {
            let wav = try Data(contentsOf: URL(fileURLWithPath: path))
            let began = Date()
            let heard = try await transcriber.transcribe(wav: wav, prompt: context.dictionary.recognitionPrompt())
            let speechTime = Date().timeIntervalSince(began)
            if transcribeOnly {
                print(heard)
                continue
            }
            let result = await pipeline.process(heard, context: context)
            if arguments.flag("json") {
                try printJSON(result)
                continue
            }
            let cleanupTime = Double(result.cleanMillis) / 1000
            let length = WAV.seconds(of: wav).map { String(format: "%.1f s of audio", $0) } ?? "unknown length"
            print("\(URL(fileURLWithPath: path).lastPathComponent)  (\(length))")
            print("  heard:    \(heard)")
            print("  cleaned:  \(result.finalText)")
            print("  timing:   speech \(seconds(speechTime)) + cleanup \(seconds(cleanupTime))"
                + " = \(seconds(speechTime + cleanupTime))   (\(outcome(of: result)))\n")
        } catch {
            FileHandle.standardError.write(Data("error: \(path): \(error)\n".utf8))
            status = 1
        }
    }
    await supervisor.stop()
    return status
}

func runEval(_ arguments: Arguments) async throws -> Int32 {
    let casesURL = URL(fileURLWithPath: arguments.option("cases") ?? "evals/cases.json")
    var cases = try EvalCase.load(from: casesURL)
    if let group = arguments.option("group") { cases = cases.filter { $0.group == group } }
    guard !cases.isEmpty else { throw CLIError("no cases to run") }

    let config = try engineConfig(arguments)
    let supervisor = EngineSupervisor(config: config, tracksProcesses: false)
    var cleaner: LlamaClient?
    if !arguments.flag("rules-only") {
        try await supervisor.start(speech: false, cleanup: true)
        cleaner = try await supervisor.cleaner()
    }
    let pipeline = Pipeline(cleaner: cleaner)

    struct Outcome {
        let testCase: EvalCase
        let result: PipelineResult
        let failures: [String]
    }
    var outcomes: [Outcome] = []
    for testCase in cases {
        let result = await pipeline.process(testCase.input, context: testCase.context)
        outcomes.append(Outcome(testCase: testCase, result: result, failures: testCase.failures(in: result.finalText)))
    }
    await supervisor.stop()

    for item in outcomes where arguments.flag("verbose") || !item.failures.isEmpty {
        print("\(item.failures.isEmpty ? "pass" : "FAIL")  \(item.testCase.id)")
        print("      in:  \(item.testCase.input)")
        print("      out: \(String(reflecting: item.result.finalText))")
        if let fallback = item.result.fallback { print("      fallback: \(fallback.rawValue)") }
        if let rejected = item.result.rejectedReply { print("      rejected reply: \(String(reflecting: rejected))") }
        for failure in item.failures { print("      - \(failure)") }
    }

    var groups: [String] = []
    for item in outcomes where !groups.contains(item.testCase.group) { groups.append(item.testCase.group) }
    print("\nGroup            Passed")
    for group in groups {
        let members = outcomes.filter { $0.testCase.group == group }
        let passed = members.filter { $0.failures.isEmpty }.count
        print("\(group.padding(toLength: 16, withPad: " ", startingAt: 0)) \(passed)/\(members.count)")
    }
    let passed = outcomes.filter { $0.failures.isEmpty }.count
    let percent = Int((Double(passed) / Double(outcomes.count) * 100).rounded())
    print("\("Total".padding(toLength: 16, withPad: " ", startingAt: 0)) \(passed)/\(outcomes.count) (\(percent)%)")

    if cleaner == nil {
        print("\nCleanup model:   none (rules only)")
        return 0
    }
    print("\nCleanup model:   \(config.cleanupModel.fileName) (\(config.cleanupModel.style.rawValue) prompt)")
    let times = outcomes.filter { $0.result.llmAttempted }.map { $0.result.cleanMillis }.sorted()
    if !times.isEmpty {
        let median = times[times.count / 2]
        let high = times[min(times.count - 1, Int(Double(times.count) * 0.9))]
        print("Cleanup time:    median \(median) ms, 90th percentile \(high) ms, over \(times.count) model calls")
    }
    var reasons: [String: Int] = [:]
    for item in outcomes {
        if let fallback = item.result.fallback { reasons[fallback.rawValue, default: 0] += 1 }
    }
    let detail = reasons.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    print("Model replies rejected: \(reasons.values.reduce(0, +))" + (detail.isEmpty ? "" : " (\(detail))"))
    return 0
}

// MARK: Entry point

func run() async throws -> Int32 {
    var raw = Array(CommandLine.arguments.dropFirst())
    guard let command = raw.first else {
        print(usage)
        return 2
    }
    raw.removeFirst()
    let arguments = try Arguments(raw)
    if arguments.flag("help") || command == "help" || command == "--help" || command == "-h" {
        print(usage)
        return 0
    }
    switch command {
    case "doctor": return try runDoctor(arguments)
    case "models": return runModels()
    case "add-model": return try runAddModel(arguments)
    case "clean": return try await runClean(arguments)
    case "transcribe": return try await runDictate(arguments, transcribeOnly: true)
    case "dictate": return try await runDictate(arguments, transcribeOnly: false)
    case "eval": return try await runEval(arguments)
    default: throw CLIError("unknown command '\(command)'. Run lucid-cli help for the list.")
    }
}

let status: Int32
do {
    status = try await run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    status = 1
}
exit(status)
