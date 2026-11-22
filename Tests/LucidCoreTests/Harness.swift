import Foundation

/// A minimal test harness. XCTest is not available with the Command Line Tools alone.
final class TestRun {
    static let shared = TestRun()

    /// When set, only suites whose name contains this text are run.
    var filter: String?

    private var currentTest = ""
    private var testCount = 0
    private var checkCount = 0
    private var failures: [String] = []

    var failureCount: Int { failures.count }

    func beginSuite(_ name: String) -> Bool {
        if let filter, !name.lowercased().contains(filter.lowercased()) { return false }
        print(name)
        return true
    }

    func begin(_ name: String) {
        currentTest = name
        testCount += 1
    }

    func end(failuresBefore: Int) {
        print(failures.count == failuresBefore ? "  ok    \(currentTest)" : "  FAIL  \(currentTest)")
    }

    func check() {
        checkCount += 1
    }

    func fail(_ message: String, file: String, line: Int) {
        let entry = "\(file):\(line)  [\(currentTest)]  \(message)"
        failures.append(entry)
        print("        \(entry)")
    }

    func finish() -> Never {
        print("")
        if testCount == 0 {
            print("FAILED  no tests matched")
            exit(1)
        }
        if failures.isEmpty {
            print("PASSED  \(testCount) tests, \(checkCount) checks")
            exit(0)
        }
        print("FAILED  \(failures.count) of \(checkCount) checks, in \(testCount) tests")
        for failure in failures { print("  \(failure)") }
        exit(1)
    }
}

func suite(_ name: String, _ body: () -> Void) {
    if TestRun.shared.beginSuite(name) { body() }
}

func asyncSuite(_ name: String, _ body: () async -> Void) async {
    if TestRun.shared.beginSuite(name) { await body() }
}

func test(_ name: String, _ body: () throws -> Void) {
    let run = TestRun.shared
    run.begin(name)
    let before = run.failureCount
    do {
        try body()
    } catch {
        run.fail("threw \(error)", file: #fileID, line: #line)
    }
    run.end(failuresBefore: before)
}

func asyncTest(_ name: String, _ body: () async throws -> Void) async {
    let run = TestRun.shared
    run.begin(name)
    let before = run.failureCount
    do {
        try await body()
    } catch {
        run.fail("threw \(error)", file: #fileID, line: #line)
    }
    run.end(failuresBefore: before)
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: String = #fileID, line: Int = #line) {
    TestRun.shared.check()
    if actual != expected {
        TestRun.shared.fail(
            "expected \(String(reflecting: expected)) but got \(String(reflecting: actual))",
            file: file, line: line
        )
    }
}

func expectTrue(_ condition: Bool, _ message: String = "expected true", file: String = #fileID, line: Int = #line) {
    TestRun.shared.check()
    if !condition { TestRun.shared.fail(message, file: file, line: line) }
}

func expectFalse(_ condition: Bool, _ message: String = "expected false", file: String = #fileID, line: Int = #line) {
    TestRun.shared.check()
    if condition { TestRun.shared.fail(message, file: file, line: line) }
}
