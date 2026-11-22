import AppKit
import ApplicationServices
import AVFoundation

/// The two permissions Lucid needs, and the system setting that affects the Fn key.
enum Permissions {
    static var microphone: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Accessibility access lets Lucid see the dictation key and paste the result.
    static var accessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Asks macOS to show its own prompt, which offers to open System Settings.
    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    /// True when pressing Fn alone also does something in macOS, which would fight with
    /// dictation. The setting is "Press 🌐 key to" in Keyboard settings: 0 means "Do Nothing".
    /// It is unset until the user changes it, and the default is not "Do Nothing".
    static var fnKeyConflicts: Bool {
        let action = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        return action != 0
    }
}
