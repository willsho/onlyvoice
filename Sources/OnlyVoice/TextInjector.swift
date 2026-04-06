import Cocoa
import Carbon

/// Injects transcribed text into the currently focused input field.
/// Handles CJK input method switching to prevent Cmd+V interception.
final class TextInjector {

    func inject(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        // Save original clipboard contents
        let originalItems = pasteboard.pasteboardItems?.compactMap { item -> (String, String)? in
            // Save the main string types
            for type in item.types {
                if let data = item.string(forType: type) {
                    return (type.rawValue, data)
                }
            }
            return nil
        } ?? []

        // Check if current input source is CJK, switch to ASCII if needed
        let originalInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let needsSwitch = isCJKInputSource(originalInputSource)

        if needsSwitch {
            switchToASCIIInputSource()
            // Small delay to let the input source switch take effect
            usleep(50_000) // 50ms
        }

        // Set clipboard to our text
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)

        // Simulate Cmd+V
        simulatePaste()

        // Restore original input source after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if needsSwitch {
                TISSelectInputSource(originalInputSource)
            }

            // Restore original clipboard after paste completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pasteboard.clearContents()
                for (typeRaw, data) in originalItems {
                    pasteboard.setString(data, forType: NSPasteboard.PasteboardType(typeRaw))
                }
            }
        }
    }

    // MARK: - Private

    private func isCJKInputSource(_ source: TISInputSource) -> Bool {
        guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return false
        }
        let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String

        // CJK input method identifiers
        let cjkPatterns = [
            "com.apple.inputmethod.SCIM",     // Simplified Chinese
            "com.apple.inputmethod.TCIM",     // Traditional Chinese
            "com.apple.inputmethod.Japanese",  // Japanese
            "com.apple.inputmethod.Korean",    // Korean
            "com.sogou",                       // Sogou
            "com.baidu",                       // Baidu
            "com.tencent",                     // QQ Pinyin
            "com.iflytek",                     // iFlytek
            "com.apple.inputmethod.ChineseHandwriting",
            "com.google.inputmethod.Japanese",
        ]

        return cjkPatterns.contains { sourceID.hasPrefix($0) }
    }

    private func switchToASCIIInputSource() {
        // Find ABC or US keyboard
        let criteria: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsASCIICapable as String: true
        ]

        guard let sources = TISCreateInputSourceList(criteria as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
              let asciiSource = sources.first else { return }

        TISSelectInputSource(asciiSource)
    }

    private func simulatePaste() {
        // Create Cmd+V key down/up events
        let vKeyCode: CGKeyCode = 9 // 'V' key

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
