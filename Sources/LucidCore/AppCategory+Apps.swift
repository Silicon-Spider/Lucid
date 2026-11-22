import Foundation

extension AppCategory {
    // Bundle identifiers, lower-cased.
    private static let emailApps: Set<String> = [
        "com.apple.mail",
        "com.microsoft.outlook",
        "com.readdle.smartemail-mac",
        "com.superhuman.electron",
        "com.mimestream.mimestream",
        "com.freron.mailmate",
    ]

    private static let chatApps: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.apple.mobilesms",
        "net.whatsapp.whatsapp",
        "com.hnc.discord",
        "ru.keepcoder.telegram",
        "org.telegram.desktop",
        "org.whispersystems.signal-desktop",
        "com.facebook.archon",
    ]

    /// Terminals, editors and AI chat apps. Dictation here is usually a command or a prompt.
    private static let codeApps: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.microsoft.vscode",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "dev.zed.zed",
        "com.apple.dt.xcode",
        "com.anthropic.claudefordesktop",
        "com.openai.chat",
    ]

    private static let codePrefixes = ["com.jetbrains."]

    /// The category for a macOS bundle identifier. Unknown apps are `.other`.
    public static func forBundleID(_ bundleID: String?) -> AppCategory {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return .other }
        if emailApps.contains(id) { return .email }
        if chatApps.contains(id) { return .chat }
        if codeApps.contains(id) || codePrefixes.contains(where: { id.hasPrefix($0) }) { return .code }
        return .other
    }
}
