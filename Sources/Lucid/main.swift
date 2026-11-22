import AppKit

// This file stays synchronous on purpose. A top-level `await` would run the app's main
// loop inside a main-queue job, and work sent to the main queue would then never run.

let launchArguments = Array(CommandLine.arguments.dropFirst())

// Headless mode: check the engines and pipeline without a screen, keyboard or microphone.
if let index = launchArguments.firstIndex(of: "--self-test") {
    let files = Array(launchArguments[(index + 1)...])
    Task { @MainActor in
        exit(await SelfTest.run(files: files))
    }
    dispatchMain()
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.run()
