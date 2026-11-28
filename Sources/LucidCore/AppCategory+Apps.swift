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

    // Program names on Windows and Linux, lower-cased, without ".exe".
    private static let emailPrograms: Set<String> = [
        "outlook", "olk", "hxoutlook", "thunderbird", "mailspring", "mailclient",
        "betterbird", "evolution", "geary", "kmail", "claws-mail",
    ]

    private static let chatPrograms: Set<String> = [
        "slack", "teams", "ms-teams", "discord", "telegram", "whatsapp", "signal", "element",
        "telegram-desktop", "signal-desktop", "element-desktop", "teams-for-linux", "fractal", "nheko", "zulip",
    ]

    /// Terminals, editors and AI chat apps, as on the Mac.
    private static let codePrograms: Set<String> = [
        "windowsterminal", "cmd", "powershell", "pwsh", "conhost", "wezterm-gui", "alacritty",
        "code", "cursor", "windsurf", "zed", "devenv", "sublime_text", "notepad++",
        "idea64", "pycharm64", "webstorm64", "clion64", "rider64", "goland64", "rustrover64",
        "phpstorm64", "datagrip64", "studio64",
        "claude", "chatgpt",
        "gnome-terminal-server", "gnome-terminal", "konsole", "kitty", "xterm", "foot", "tilix", "ptyxis", "kgx",
        "xfce4-terminal", "terminator", "wezterm", "ghostty", "codium", "code-oss", "zed-editor", "emacs", "gvim",
    ]

    /// The category for a program on Windows or Linux, given its file name with or without ".exe".
    /// Unknown programs are `.other`.
    public static func forProgram(_ name: String?) -> AppCategory {
        guard var program = name?.lowercased(), !program.isEmpty else { return .other }
        if program.hasSuffix(".exe") { program.removeLast(4) }
        if emailPrograms.contains(program) { return .email }
        if chatPrograms.contains(program) { return .chat }
        if codePrograms.contains(program) { return .code }
        return .other
    }

    /// The category for an app, whichever way its system names it: a bundle identifier on a
    /// Mac, a program's file name on Windows and Linux.
    public static func forApp(_ id: String?) -> AppCategory {
        let category = forBundleID(id)
        return category == .other ? forProgram(id) : category
    }

    /// The category for a macOS bundle identifier. Unknown apps are `.other`.
    public static func forBundleID(_ bundleID: String?) -> AppCategory {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return .other }
        if emailApps.contains(id) { return .email }
        if chatApps.contains(id) { return .chat }
        if codeApps.contains(id) || codePrefixes.contains(where: { id.hasPrefix($0) }) { return .code }
        return .other
    }
}
