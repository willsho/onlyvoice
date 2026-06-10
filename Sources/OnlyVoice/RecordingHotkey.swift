import AppKit
import CoreGraphics

extension Notification.Name {
    /// 设置界面进入/退出快捷键录制状态。userInfo["capturing"]: Bool。
    /// 录制期间 HotkeyMonitor 暂停匹配，让按键进入设置窗口；结束后重新加载快捷键。
    static let hotkeyCaptureStateChanged = Notification.Name("hotkeyCaptureStateChanged")
}

/// 用户自定义的录音快捷键。
/// - fn: 默认。走 HID 重映射（Fn→F18）以屏蔽系统输入法切换。
/// - modifier: 单个修饰键（如右 ⌘），通过 flagsChanged 匹配按下/松开。
/// - key: 普通键或修饰键组合（如 F18、⌥Space），通过 keyDown/keyUp 匹配。
enum RecordingHotkey: Equatable {
    case fn
    case modifier(keyCode: Int64)
    case key(keyCode: Int64, modifiers: UInt)

    static let kindKey = "recording_hotkey_kind"
    static let keyCodeKey = "recording_hotkey_keycode"
    static let modifiersKey = "recording_hotkey_modifiers"

    static var current: RecordingHotkey {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: kindKey) {
        case "modifier":
            return .modifier(keyCode: Int64(defaults.integer(forKey: keyCodeKey)))
        case "key":
            return .key(keyCode: Int64(defaults.integer(forKey: keyCodeKey)),
                        modifiers: UInt(defaults.integer(forKey: modifiersKey)))
        default:
            return .fn
        }
    }

    func save() {
        let defaults = UserDefaults.standard
        switch self {
        case .fn:
            defaults.set("fn", forKey: Self.kindKey)
            defaults.set(0, forKey: Self.keyCodeKey)
            defaults.set(0, forKey: Self.modifiersKey)
        case .modifier(let keyCode):
            defaults.set("modifier", forKey: Self.kindKey)
            defaults.set(Int(keyCode), forKey: Self.keyCodeKey)
            defaults.set(0, forKey: Self.modifiersKey)
        case .key(let keyCode, let modifiers):
            defaults.set("key", forKey: Self.kindKey)
            defaults.set(Int(keyCode), forKey: Self.keyCodeKey)
            defaults.set(Int(modifiers), forKey: Self.modifiersKey)
        }
    }

    var displayName: String {
        switch self {
        case .fn:
            return "Fn"
        case .modifier(let keyCode):
            return KeyNames.modifierName(keyCode) ?? "Key \(keyCode)"
        case .key(let keyCode, let modifiers):
            let flags = NSEvent.ModifierFlags(rawValue: modifiers)
            var symbols = ""
            if flags.contains(.control) { symbols += "⌃" }
            if flags.contains(.option) { symbols += "⌥" }
            if flags.contains(.shift) { symbols += "⇧" }
            if flags.contains(.command) { symbols += "⌘" }
            return symbols + (KeyNames.keyName(keyCode) ?? "Key \(keyCode)")
        }
    }

    /// 不带修饰键时允许单独作为快捷键的键（F1–F20）。
    /// 字母/数字等裸键会吞掉正常输入，不允许。
    static func isAllowedBareKey(_ keyCode: Int64) -> Bool {
        KeyNames.functionKeyCodes.contains(keyCode)
    }
}

/// 键码 → 显示名（ANSI 布局）。
enum KeyNames {
    static let functionKeyCodes: Set<Int64> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90
    ]

    private static let names: [Int64: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌅",
        114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20"
    ]

    private static let modifierNames: [Int64: String] = [
        54: "Right ⌘", 55: "Left ⌘",
        56: "Left ⇧", 60: "Right ⇧",
        58: "Left ⌥", 61: "Right ⌥",
        59: "Left ⌃", 62: "Right ⌃",
        63: "Fn"
    ]

    static func keyName(_ keyCode: Int64) -> String? {
        names[keyCode]
    }

    static func modifierName(_ keyCode: Int64) -> String? {
        modifierNames[keyCode]
    }

    /// flagsChanged 事件里修饰键键码对应的 NSEvent 标志位。
    static func modifierFlag(for keyCode: Int64) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
        default: return nil
        }
    }

    /// 修饰键键码对应的 CGEventFlags 掩码（event tap 侧判断按下/松开）。
    static func cgModifierMask(for keyCode: Int64) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        default: return nil
        }
    }

    /// NSEvent.ModifierFlags（设置界面捕获）→ CGEventFlags（event tap 匹配）。
    static func cgFlags(fromModifiers raw: UInt) -> CGEventFlags {
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        var cg: CGEventFlags = []
        if flags.contains(.command) { cg.insert(.maskCommand) }
        if flags.contains(.option) { cg.insert(.maskAlternate) }
        if flags.contains(.control) { cg.insert(.maskControl) }
        if flags.contains(.shift) { cg.insert(.maskShift) }
        return cg
    }
}
