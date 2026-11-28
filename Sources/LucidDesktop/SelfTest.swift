import CLucidWin
import Foundation
import LucidApp
import LucidCore
import LucidEngines
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Starts the app in a folder of its own, tries the parts that need Windows, and writes down
/// what it found. `Lucid.exe --self-test report.txt` is how automated builds check the app,
/// since nobody is there to hold a key.
enum SelfTest {
    private final class Report {
        var lines: [String] = []
        var failed = false

        /// Something that must work for the app to be of any use.
        func must(_ passed: Bool, _ what: String) {
            lines.append("\(passed ? "ok   " : "FAIL ") \(what)")
            if !passed { failed = true }
        }

        /// Something that depends on the PC: a microphone, a desktop someone is signed in to.
        func note(_ what: String) {
            lines.append("     \(what)")
        }
    }

    static func run(reportPath: String?) -> Int32 {
        let report = Report()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lucid-self-test-\(UUID().uuidString)")
        let pictures = reportPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        do {
            let library = ModelLibrary(directory: folder.appendingPathComponent("models"))
            let app = try WindowsApp(folder: folder, library: library, tracksProcesses: false)
            report.must(app.start(), "Windows gives Lucid its window, tray icon and pill")
            check(app, report, pictures: pictures)
            lucid_quit()
            _ = lucid_run()
            app.desk.server.stop()
            lucid_stop()
        } catch {
            report.must(false, "the app starts: \(error)")
        }

        let text = (report.lines + [report.failed ? "FAILED" : "PASSED"]).joined(separator: "\n") + "\n"
        print(text, terminator: "")
        if let reportPath { try? text.write(toFile: reportPath, atomically: true, encoding: .utf8) }
        return report.failed ? 1 : 0
    }

    private static func check(_ app: WindowsApp, _ report: Report, pictures: URL) {
        let shell = app.shell
        report.note("tray icon shown: \(lucid_tray_shown())")
        report.note("listening for the dictation key: \(lucid_keyboard_watched())")
        report.note("microphones: \(lucid_mic_devices()), allowed by Windows: \(lucid_mic_allowed())")
        report.note("opens at sign-in: \(lucid_opens_at_login())")
        report.note("a console without a window for the engines: \(lucid_hide_consoles())")
        let front = shell.captureTarget()
        report.note("app in front: \(front.appName) (\(front.appID ?? "none"))")
        report.note("status: \(app.statusLine)")

        // The menu, as text.
        let menu = app.menuLines()
        report.must(menu.first?.title == app.statusLine && menu.last?.title == "Quit Lucid", "builds the tray menu")
        for line in menu where !line.title.isEmpty { report.note("  menu: \(line.title)") }

        // The window: the page and what it asks, over the network on this PC.
        app.desk.server.start()
        let state = fetch(app.desk.server.address + "/api/state", key: app.desk.key)
        report.must(state.status == 200 && state.body.contains("\"canDictate\":true"), "serves the window's page what it asks (\(state.status))")
        let page = fetch(app.desk.server.address + "/", key: "")
        report.must(page.status == 200 && page.body.contains("<title>Lucid</title>"), "serves the window's page (\(page.status))")
        let refused = fetch(app.desk.server.address + "/api/state", key: "")
        report.must(refused.status == 403, "refuses a request without the key (\(refused.status))")

        // The clipboard.
        let words = "Café — done 🎉"
        shell.copy(words)
        let copied = text { lucid_clipboard_text($0, $1) }
        report.note("clipboard round trip: \(copied == words ? "ok" : "got \"\(copied)\"")")

        // The pill, drawn by Windows with its own font.
        lucid_test_level(0.08)
        shell.showPill(.recording)
        shell.setPreview("so let's meet at three")
        lucid_pump(200)
        report.note("pill visible while recording: \(lucid_pill_visible())")
        report.must(
            lucid_test_pill_picture(pictures.appendingPathComponent("app-pill-recording.bmp").path, 0x7a8aa0),
            "draws the pill"
        )
        shell.showPill(.processing)
        lucid_pump(300)
        _ = lucid_test_pill_picture(pictures.appendingPathComponent("app-pill-processing.bmp").path, 0x7a8aa0)
        shell.flashPill("Copied. Press Ctrl+V", seconds: 0.2)
        lucid_pump(100)
        _ = lucid_test_pill_picture(pictures.appendingPathComponent("app-pill-message.bmp").path, 0x7a8aa0)
        lucid_pump(400)
        lucid_test_level(-1)
        report.note("pill hidden again: \(!lucid_pill_visible())")
        report.must(
            lucid_test_tray_picture(pictures.appendingPathComponent("app-tray.bmp").path, 0x7a8aa0),
            "draws the tray icon"
        )

        // The dictation key, pressed the way a program can. With no microphone the pill says
        // so, and with one, recording starts. Either way the key reached the app.
        lucid_test_accept_made_up_keys(true)
        let pressed = lucid_test_press(WindowsHotkey.rightControl.virtualKey, true)
        lucid_pump(400)
        let answered = lucid_pill_visible()
        _ = lucid_test_press(WindowsHotkey.rightControl.virtualKey, false)
        lucid_pump(200)
        // Escape cancels a recording that the press may have started.
        if app.desk.driver.isRecording {
            _ = lucid_test_press(0x1B, true)
            _ = lucid_test_press(0x1B, false)
            lucid_pump(300)
        }
        lucid_test_accept_made_up_keys(false)
        report.note("dictation key pressed by the test: \(pressed), answered by the pill: \(answered)")
    }

    private static func fetch(_ address: String, key: String) -> (status: Int, body: String) {
        guard let url = URL(string: address) else { return (0, "") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Lucid-Key") }
        let done = DispatchSemaphore(value: 0)
        let result = Answer()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result.body = String(decoding: data ?? Data(), as: UTF8.self)
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        return (result.status, result.body)
    }

    /// What a request came back with, filled in on another thread.
    private final class Answer: @unchecked Sendable {
        var status = 0
        var body = ""
    }
}
