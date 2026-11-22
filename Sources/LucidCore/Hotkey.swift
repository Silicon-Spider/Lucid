import Foundation

/// The keys that can start a dictation. All are modifier keys, so holding one types nothing.
public enum HotkeyChoice: String, Codable, CaseIterable, Sendable {
    case fn
    case rightOption
    case rightCommand

    /// The macOS virtual key code reported when this key goes down or up.
    public var keyCode: Int {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        }
    }

    public var title: String {
        switch self {
        case .fn: return "Fn (Globe)"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        }
    }

    /// Fn on a MacBook, where the key is built in. Right Option elsewhere, because many
    /// external keyboards do not report Fn to macOS.
    public static func standard(forModelName name: String) -> HotkeyChoice {
        name.contains("MacBook") ? .fn : .rightOption
    }
}
