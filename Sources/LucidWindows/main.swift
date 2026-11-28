import CLucidWin
import Foundation
import LucidApp

// Lucid for Windows. It lives beside the clock: hold the dictation key and speak.

let arguments = CommandLine.arguments

if let flag = arguments.firstIndex(of: "--self-test") {
    // Checks the parts that need Windows, and writes down what it found. For automated builds.
    let report = arguments.dropFirst(flag + 1).first
    exit(SelfTest.run(reportPath: report))
}

// Two copies would both answer the dictation key. The first has been asked to show its window.
guard lucid_claim_single_instance() else { exit(0) }

do {
    let app = try WindowsApp()
    guard app.start() else {
        lucid_alert("Lucid", "Windows would not let Lucid start. Restarting the PC usually helps.")
        exit(1)
    }
    exit(app.run())
} catch {
    lucid_alert("Lucid", "Lucid could not start. \(error)")
    exit(1)
}
