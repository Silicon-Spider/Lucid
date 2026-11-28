import CLucidDesk
import Foundation
import LucidApp

// Lucid for Windows and for Linux. It lives beside the clock: hold the dictation key and speak.

let arguments = CommandLine.arguments

if let flag = arguments.firstIndex(of: "--self-test") {
    // Checks the parts that need the desktop, and writes down what it found. For automated builds.
    let report = arguments.dropFirst(flag + 1).first
    exit(SelfTest.run(reportPath: report))
}

if arguments.contains("--install-launcher") {
    // Adds Lucid to the desktop's menu of applications, so it opens without a terminal.
    // scripts/setup-linux.sh does this once the app is built.
    exit(lucid_install_launcher() ? 0 : 1)
}

// Two copies would both answer the dictation key. The first has been asked to show its window.
guard lucid_claim_single_instance() else { exit(0) }

do {
    let app = try DesktopApp()
    guard app.start() else {
        #if os(Windows)
        lucid_alert("Lucid", "Windows would not let Lucid start. Restarting the PC usually helps.")
        #else
        lucid_alert("Lucid", "Lucid could not reach the display. It needs a desktop with X11, or Wayland with its X11 bridge.")
        #endif
        exit(1)
    }
    exit(app.run())
} catch {
    lucid_alert("Lucid", "Lucid could not start. \(error)")
    exit(1)
}
