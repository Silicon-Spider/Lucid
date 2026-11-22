import Foundation
import IOKit.ps
import LucidCore

enum SystemInfo {
    /// True on a Mac with a built-in battery, which also means a built-in keyboard with an Fn key.
    static var isLaptop: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else { return false }
        for source in list as [AnyObject] {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            if details[kIOPSTypeKey] as? String == kIOPSInternalBatteryType { return true }
        }
        return false
    }

    static var defaultHotkey: HotkeyChoice {
        HotkeyChoice.standard(forModelName: isLaptop ? "MacBook" : "Mac")
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }
}
