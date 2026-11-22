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

// Headless mode: draw the app's views to PNG files.
if let index = launchArguments.firstIndex(of: "--render-ui"), index + 1 < launchArguments.count {
    let folder = URL(fileURLWithPath: launchArguments[index + 1])
    exit(MainActor.assumeIsolated { UIRenderer.render(into: folder) })
}

let application = NSApplication.shared
let appDelegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
