import Cocoa
import Carbon
import ApplicationServices

/// Monitors the user-configured recording hotkey globally (default: Fn).
/// Fn preferred path: remap Fn/Globe to F18 at the HID layer so macOS never
/// shows the input-source picker; fallback keeps event-tap interception plus
/// input source restoration. Other hotkeys (lone modifier / key combo) are
/// matched and suppressed directly in the event tap.
final class HotkeyMonitor {
    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    /// Called when accessibility permission is required but not yet granted.
    var onPermissionRequired: (() -> Void)?
    /// Called when accessibility permission is granted and event tap is active.
    var onPermissionGranted: (() -> Void)?

    private enum TriggerMode {
        case remappedF18
        case nativeFn
        case modifierKey(keyCode: Int64, mask: CGEventFlags)
        case comboKey(keyCode: Int64, requiredFlags: CGEventFlags)
    }

    private static let remappedF18KeyCode: Int64 = 79
    private static let nativeFnGlobeKeyCode: Int64 = 79
    private static let fnHIDUsage: UInt64 = 0xFF00000003
    private static let f18HIDUsage: UInt64 = 0x70000006D
    private static let hidSrcKey = "HIDKeyboardModifierMappingSrc"
    private static let hidDstKey = "HIDKeyboardModifierMappingDst"
    /// Settings 的快捷键录制界面也要读这个 key：remap 生效期间按 Fn 实际产生 F18。
    static let remapDefaultsKey = "onlyvoice_fn_remap_active"
    private static let restoreRetryInterval: TimeInterval = 0.05
    private static let restoreRetryCount = 12
    private static let restoreWindow: CFTimeInterval = 1.0

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var inputSourceObserver: NSObjectProtocol?
    private var triggerIsDown = false
    private var permissionPollTimer: Timer?
    private var triggerMode: TriggerMode = .nativeFn
    private var fnRemapActive = false
    private var fnRemapInstalledByOnlyVoice = false
    /// 设置界面录制快捷键期间为 true：event tap 不匹配、全部放行。
    private var isSuspended = false

    /// Input source saved when Fn is pressed, restored on release to undo
    /// any system-level input method switch that we cannot suppress via event tap.
    private var savedInputSource: TISInputSource?
    private var savedInputSourceID: String?
    private var restoreGeneration = 0
    private var restoreDeadline: CFTimeInterval = 0

    @discardableResult
    func ensureAccessibilityPermission(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [key: prompt]
        return AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        cleanupStaleFnRemapIfNeeded()

        if !ensureAccessibilityPermission(prompt: true) {
            print("[HotkeyMonitor] Accessibility permission not granted yet. Polling until granted...")
            DispatchQueue.main.async { self.onPermissionRequired?() }
            startPermissionPolling()
            return
        }
        stopPermissionPolling()
        startObservingInputSourceChanges()
        configureTriggerMode()

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: fnKeyCallback,
            userInfo: selfPtr
        ) else {
            print("[HotkeyMonitor] Failed to create event tap. Check Accessibility permissions.")
            stopObservingInputSourceChanges()
            removeFnRemapIfNeeded()
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        stopPermissionPolling()
        stopObservingInputSourceChanges()
        removeFnRemapIfNeeded()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        triggerIsDown = false
        restoreDeadline = 0
        triggerMode = .nativeFn
        fnRemapInstalledByOnlyVoice = false
    }

    // MARK: - Hotkey Capture Suspension

    /// 录制新快捷键时暂停匹配（事件全部放行进设置窗口）。
    /// Fn remap 保持安装，录制端把 F18 keyDown 视作 Fn。
    func suspendMonitoring() {
        isSuspended = true
        triggerIsDown = false
    }

    /// 录制结束：重新读取 RecordingHotkey 并按新配置接管。
    func resumeMonitoring() {
        isSuspended = false
        triggerIsDown = false
        guard eventTap != nil else { return }
        configureTriggerMode()
    }

    // MARK: - Permission Polling

    private func startPermissionPolling() {
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                print("[HotkeyMonitor] Accessibility permission granted, starting event tap.")
                self.stopPermissionPolling()
                self.start()
                DispatchQueue.main.async { self.onPermissionGranted?() }
            }
        }
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    // MARK: - HID Remapping

    private func configureTriggerMode() {
        switch RecordingHotkey.current {
        case .fn:
            if applyFnRemapIfPossible() {
                triggerMode = .remappedF18
                print("[HotkeyMonitor] Using Fn->F18 remap.")
            } else {
                triggerMode = .nativeFn
                print("[HotkeyMonitor] Fn remap unavailable, falling back to native interception.")
            }
        case .modifier(let keyCode):
            removeFnRemapIfNeeded()
            triggerMode = .modifierKey(keyCode: keyCode,
                                       mask: KeyNames.cgModifierMask(for: keyCode) ?? [])
            print("[HotkeyMonitor] Using modifier key trigger (keycode \(keyCode)).")
        case .key(let keyCode, let modifiers):
            removeFnRemapIfNeeded()
            triggerMode = .comboKey(keyCode: keyCode,
                                    requiredFlags: KeyNames.cgFlags(fromModifiers: modifiers))
            print("[HotkeyMonitor] Using key trigger (keycode \(keyCode), modifiers \(modifiers)).")
        }
    }

    private func cleanupStaleFnRemapIfNeeded() {
        guard UserDefaults.standard.bool(forKey: Self.remapDefaultsKey) else { return }
        _ = removeFnRemap()
    }

    private func applyFnRemapIfPossible() -> Bool {
        guard !fnRemapActive else { return true }

        guard var mappings = fetchUserKeyMappings() else { return false }
        let remap = Self.fnRemapMapping
        let alreadyExists = mappings.contains(where: Self.isFnRemapMapping)
        if !alreadyExists {
            mappings.append(remap)
            guard setUserKeyMappings(mappings) else { return false }
        }

        fnRemapActive = true
        fnRemapInstalledByOnlyVoice = !alreadyExists
        UserDefaults.standard.set(fnRemapInstalledByOnlyVoice, forKey: Self.remapDefaultsKey)
        return true
    }

    private func removeFnRemapIfNeeded() {
        guard fnRemapInstalledByOnlyVoice || UserDefaults.standard.bool(forKey: Self.remapDefaultsKey) else { return }
        _ = removeFnRemap()
    }

    @discardableResult
    private func removeFnRemap() -> Bool {
        guard let mappings = fetchUserKeyMappings() else { return false }
        let filtered = mappings.filter { !Self.isFnRemapMapping($0) }
        let success = mappings.count == filtered.count || setUserKeyMappings(filtered)
        if success {
            fnRemapActive = false
            fnRemapInstalledByOnlyVoice = false
            UserDefaults.standard.set(false, forKey: Self.remapDefaultsKey)
        }
        return success
    }

    /// Parses `hidutil property --get UserKeyMapping` output.
    /// macOS <= 26 prints a single plist array; macOS 27 prints a per-device
    /// table (RegistryID / Key / Value) where numbers may appear as quoted
    /// signed values. Extracting Src/Dst pairs via regex and deduplicating
    /// handles both formats.
    private func fetchUserKeyMappings() -> [[String: UInt64]]? {
        guard let output = runHidutil(arguments: ["property", "--get", "UserKeyMapping"]) else {
            return nil
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "(null)" {
            return []
        }

        var mappings: [[String: UInt64]] = []
        var seenPairs = Set<String>()

        let dictRegex = try! NSRegularExpression(pattern: "\\{[^{}]*\\}")
        let fullRange = NSRange(trimmed.startIndex..., in: trimmed)
        for match in dictRegex.matches(in: trimmed, range: fullRange) {
            guard let range = Range(match.range, in: trimmed) else { continue }
            let body = String(trimmed[range])
            guard let src = Self.hidMappingValue(in: body, key: Self.hidSrcKey),
                  let dst = Self.hidMappingValue(in: body, key: Self.hidDstKey) else {
                continue
            }
            let pairKey = "\(src)->\(dst)"
            guard seenPairs.insert(pairKey).inserted else { continue }
            mappings.append([
                Self.hidSrcKey: src,
                Self.hidDstKey: dst
            ])
        }

        return mappings
    }

    private static func hidMappingValue(in body: String, key: String) -> UInt64? {
        guard let regex = try? NSRegularExpression(pattern: "\(key)\\s*=\\s*\"?(-?\\d+)\"?"),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else {
            return nil
        }
        let literal = String(body[range])
        if literal.hasPrefix("-") {
            guard let signed = Int64(literal) else { return nil }
            return UInt64(bitPattern: signed)
        }
        return UInt64(literal)
    }

    private func setUserKeyMappings(_ mappings: [[String: UInt64]]) -> Bool {
        let payloadMappings = mappings.map { mapping in
            [
                Self.hidSrcKey: NSNumber(value: mapping[Self.hidSrcKey] ?? 0),
                Self.hidDstKey: NSNumber(value: mapping[Self.hidDstKey] ?? 0)
            ]
        }
        let payload: [String: Any] = ["UserKeyMapping": payloadMappings]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8),
              runHidutil(arguments: ["property", "--set", json]) != nil else {
            return false
        }

        return true
    }

    private func runHidutil(arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        task.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("[HotkeyMonitor] Failed to launch hidutil: \(error)")
            return nil
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        guard task.terminationStatus == 0 else {
            if let message = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                print("[HotkeyMonitor] hidutil failed: \(message)")
            }
            return nil
        }

        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    private static var fnRemapMapping: [String: UInt64] {
        [
            hidSrcKey: fnHIDUsage,
            hidDstKey: f18HIDUsage
        ]
    }

    private static func isFnRemapMapping(_ mapping: [String: UInt64]) -> Bool {
        mapping[hidSrcKey] == fnHIDUsage && mapping[hidDstKey] == f18HIDUsage
    }

    // MARK: - Input Source Save / Restore

    private func startObservingInputSourceChanges() {
        guard inputSourceObserver == nil else { return }
        let notificationName = NSNotification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String)
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSelectedInputSourceChanged()
        }
    }

    private func stopObservingInputSourceChanges() {
        if let observer = inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            inputSourceObserver = nil
        }
    }

    private func saveCurrentInputSource() {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        savedInputSource = source
        savedInputSourceID = inputSourceID(for: source)
        restoreGeneration += 1
        restoreDeadline = 0
    }

    private func restoreInputSourceIfNeeded() {
        guard let saved = savedInputSource,
              let savedID = savedInputSourceID else { return }
        restoreGeneration += 1
        restoreDeadline = CACurrentMediaTime() + Self.restoreWindow
        restoreInputSourceIfChanged(saved, savedID: savedID)
        scheduleInputSourceRestore(
            saved,
            savedID: savedID,
            generation: restoreGeneration,
            remainingAttempts: Self.restoreRetryCount
        )
    }

    private func scheduleInputSourceRestore(
        _ saved: TISInputSource,
        savedID: String,
        generation: Int,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreRetryInterval) { [weak self] in
            guard let self = self,
                  self.restoreGeneration == generation else { return }

            self.restoreInputSourceIfChanged(saved, savedID: savedID)

            if remainingAttempts == 1 {
                self.clearSavedInputSourceIfStale(generation: generation)
                return
            }

            self.scheduleInputSourceRestore(
                saved,
                savedID: savedID,
                generation: generation,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private func handleSelectedInputSourceChanged() {
        guard case .nativeFn = triggerMode,
              CACurrentMediaTime() <= restoreDeadline,
              let saved = savedInputSource,
              let savedID = savedInputSourceID else { return }
        restoreInputSourceIfChanged(saved, savedID: savedID)
    }

    private func restoreInputSourceIfChanged(_ saved: TISInputSource, savedID: String) {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard inputSourceID(for: current) != savedID else { return }
        TISSelectInputSource(saved)
    }

    private func clearSavedInputSourceIfStale(generation: Int) {
        guard restoreGeneration == generation else { return }
        savedInputSource = nil
        savedInputSourceID = nil
        restoreDeadline = 0
    }

    private func inputSourceID(for source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    // MARK: - Event Handling

    fileprivate func handleEvent(_ event: CGEvent, type: CGEventType) -> Bool {
        guard !isSuspended else { return false }
        switch triggerMode {
        case .remappedF18:
            return handleRemappedF18(event, type: type)
        case .nativeFn:
            return handleNativeFn(event, type: type)
        case .modifierKey(let keyCode, let mask):
            return handleModifierKey(event, type: type, keyCode: keyCode, mask: mask)
        case .comboKey(let keyCode, let requiredFlags):
            return handleComboKey(event, type: type, keyCode: keyCode, requiredFlags: requiredFlags)
        }
    }

    private func handleRemappedF18(_ event: CGEvent, type: CGEventType) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keycode == Self.remappedF18KeyCode else { return false }

        if type == .keyDown && !triggerIsDown {
            triggerIsDown = true
            DispatchQueue.main.async { [weak self] in self?.onHotkeyDown?() }
            return true
        } else if type == .keyUp && triggerIsDown {
            triggerIsDown = false
            DispatchQueue.main.async { [weak self] in self?.onHotkeyUp?() }
            return true
        }

        return true
    }

    private func handleNativeFn(_ event: CGEvent, type: CGEventType) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if keycode == Self.nativeFnGlobeKeyCode {
            if type == .keyDown && !triggerIsDown {
                triggerIsDown = true
                saveCurrentInputSource()
                DispatchQueue.main.async { [weak self] in self?.onHotkeyDown?() }
                return true
            } else if type == .keyUp && triggerIsDown {
                triggerIsDown = false
                restoreInputSourceIfNeeded()
                DispatchQueue.main.async { [weak self] in self?.onHotkeyUp?() }
                return true
            }
            return true
        }

        if type == .flagsChanged {
            let isFnPressed = flags.contains(.maskSecondaryFn)
            if isFnPressed && !triggerIsDown {
                triggerIsDown = true
                saveCurrentInputSource()
                DispatchQueue.main.async { [weak self] in self?.onHotkeyDown?() }
                return true
            } else if !isFnPressed && triggerIsDown {
                triggerIsDown = false
                restoreInputSourceIfNeeded()
                DispatchQueue.main.async { [weak self] in self?.onHotkeyUp?() }
                return true
            }
        }

        return false
    }

    /// 单修饰键触发（如右 ⌘）：按 flagsChanged 的 keycode 精确匹配左右键，
    /// 用对应掩码位判断按下/松开。该键自身的 flagsChanged 被吞掉。
    private func handleModifierKey(
        _ event: CGEvent, type: CGEventType, keyCode: Int64, mask: CGEventFlags
    ) -> Bool {
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == keyCode else {
            return false
        }

        let pressed = event.flags.contains(mask)
        if pressed && !triggerIsDown {
            triggerIsDown = true
            DispatchQueue.main.async { [weak self] in self?.onHotkeyDown?() }
        } else if !pressed && triggerIsDown {
            triggerIsDown = false
            DispatchQueue.main.async { [weak self] in self?.onHotkeyUp?() }
        }
        return true
    }

    /// 普通键 / 组合键触发（如 F18、⌥Space）。keyDown 要求修饰键精确匹配；
    /// keyUp 只看 keycode（此时修饰键可能已先松开）。自动重复的 keyDown 吞掉。
    private func handleComboKey(
        _ event: CGEvent, type: CGEventType, keyCode: Int64, requiredFlags: CGEventFlags
    ) -> Bool {
        guard type == .keyDown || type == .keyUp,
              event.getIntegerValueField(.keyboardEventKeycode) == keyCode else {
            return false
        }

        if type == .keyUp {
            guard triggerIsDown else { return false }
            triggerIsDown = false
            DispatchQueue.main.async { [weak self] in self?.onHotkeyUp?() }
            return true
        }

        if triggerIsDown {
            return true // swallow auto-repeat while held
        }

        let standardModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard event.flags.intersection(standardModifiers) == requiredFlags else { return false }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }

        triggerIsDown = true
        DispatchQueue.main.async { [weak self] in self?.onHotkeyDown?() }
        return true
    }
}

private func fnKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard (type == .flagsChanged || type == .keyDown || type == .keyUp),
          let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let shouldSuppress = monitor.handleEvent(event, type: type)

    if shouldSuppress {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
