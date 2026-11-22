import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Where the dictated text is going, captured when the user stops speaking.
struct InsertionTarget {
    var appName: String
    var bundleID: String?
    /// The few characters just before the cursor. Nil when the app does not reveal them.
    var before: String?
    /// True in a password field. Lucid never pastes there.
    var isSecure: Bool
    /// True when the focused control is clearly not somewhere text can go, such as a button.
    var isClearlyNotText: Bool
}

/// Reads the cursor's surroundings and pastes text at the cursor.
enum TextInserter {
    /// Controls that never take typed text. Anything else, including a control the
    /// Accessibility API cannot describe, is given the benefit of the doubt.
    private static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuBarItem", "AXMenuButton",
        "AXPopUpButton", "AXImage", "AXList", "AXTable", "AXOutline", "AXRow", "AXCell",
        "AXToolbar", "AXTabGroup", "AXSlider", "AXScrollBar", "AXDockItem",
    ]

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func captureTarget() -> InsertionTarget {
        let app = NSWorkspace.shared.frontmostApplication
        var target = InsertionTarget(
            appName: app?.localizedName ?? "Unknown app",
            bundleID: app?.bundleIdentifier,
            before: nil,
            isSecure: IsSecureEventInputEnabled(),
            isClearlyNotText: false
        )

        let system = AXUIElementCreateSystemWide()
        // An app that is busy must not make dictation hang.
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return target
        }
        let element = focused as! AXUIElement

        if let role = string(element, kAXRoleAttribute) {
            target.isClearlyNotText = nonTextRoles.contains(role)
        }
        if string(element, kAXSubroleAttribute) == "AXSecureTextField" {
            target.isSecure = true
        }
        target.before = textBeforeCursor(element)
        return target
    }

    /// Pastes the text at the cursor. Returns false when it was left on the clipboard instead.
    @discardableResult
    static func insert(_ text: String, into target: InsertionTarget) -> Bool {
        if target.isSecure || target.isClearlyNotText {
            copy(text)
            return false
        }
        paste(text)
        return true
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Up to three characters before the cursor. An empty string means the cursor is at the
    /// very start. Nil means the app does not say.
    private static func textBeforeCursor(_ element: AXUIElement) -> String? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) else { return nil }
        if selection.location <= 0 { return "" }

        let length = min(3, selection.location)
        var wanted = CFRange(location: selection.location - length, length: length)
        guard let parameter = AXValueCreate(.cfRange, &wanted) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &text
        ) == .success else { return nil }
        return text as? String
    }

    /// Puts the text on the clipboard, presses Command-V, then restores the clipboard.
    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }

        // Marked transient, so clipboard managers do not record the dictation.
        pasteboard.declareTypes([.string, transientType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: transientType)
        let ours = pasteboard.changeCount

        postCommandV()

        // Give the app time to read the clipboard, then put back what was there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // If the count moved, the user copied something else. Leave that alone.
            guard pasteboard.changeCount == ours else { return }
            pasteboard.clearContents()
            let items = saved.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyV: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
