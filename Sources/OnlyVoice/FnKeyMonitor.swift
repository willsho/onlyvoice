import Cocoa
import Carbon
import ApplicationServices

/// Monitors Fn key press/release globally.
/// Preferred path: remap Fn/Globe to F18 at the HID layer so macOS never shows
/// the input-source picker. Fallback path keeps the previous event-tap based
/// interception and input source restoration logic.
final class FnKeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?
    /// Called when accessibility permission is required but not yet granted.
    var onPermissionRequired: (() -> Void)?
    /// Called when accessibility permission is granted and event tap is active.
    var onPermissionGranted: (() -> Void)?

    private enum TriggerMode {
        case remappedF18
        case nativeFn
    }

    private static let remappedF18KeyCode: Int64 = 79
    private static let nativeFnGlobeKeyCode: Int64 = 79
    private static let fnHIDUsage: UInt64 = 0xFF00000003
    private static let f18HIDUsage: UInt64 = 0x70000006D
    private static let hidSrcKey = "HIDKeyboardModifierMappingSrc"
    private static let hidDstKey = "HIDKeyboardModifierMappingDst"
    private static let remapDefaultsKey = "onlyvoice_fn_remap_active"
    private static let restoreRetryInterval: TimeInterval = 0.05
    private static let restoreRetryCount = 12
    private static let restoreWindow: CFTimeInterval = 1.0

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var inputSourceObserver: NSObjectProtocol?
    private var fnIsDown = false
    private var permissionPollTimer: Timer?
    private var triggerMode: TriggerMode = .nativeFn
    private var fnRemapActive = false
    private var fnRemapInstalledByOnlyVoice = false

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
            print("[FnKeyMonitor] Accessibility permission not granted yet. Polling until granted...")
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
            print("[FnKeyMonitor] Failed to create event tap. Check Accessibility permissions.")
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
        fnIsDown = false
        restoreDeadline = 0
        triggerMode = .nativeFn
        fnRemapInstalledByOnlyVoice = false
    }

    // MARK: - Permission Polling

    private func startPermissionPolling() {
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                print("[FnKeyMonitor] Accessibility permission granted, starting event tap.")
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
        if applyFnRemapIfPossible() {
            triggerMode = .remappedF18
            print("[FnKeyMonitor] Using Fn->F18 remap.")
        } else {
            triggerMode = .nativeFn
            print("[FnKeyMonitor] Fn remap unavailable, falling back to native interception.")
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

    private func fetchUserKeyMappings() -> [[String: UInt64]]? {
        guard let output = runHidutil(arguments: ["property", "--get", "UserKeyMapping"]) else {
            return nil
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "(null)" {
            return []
        }

        guard let data = trimmed.data(using: .utf8) else { return nil }

        do {
            var format = PropertyListSerialization.PropertyListFormat.openStep
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
            guard let items = plist as? [[String: Any]] else { return nil }
            return items.compactMap { item in
                guard let src = (item[Self.hidSrcKey] as? NSNumber)?.uint64Value,
                      let dst = (item[Self.hidDstKey] as? NSNumber)?.uint64Value else {
                    return nil
                }
                return [
                    Self.hidSrcKey: src,
                    Self.hidDstKey: dst
                ]
            }
        } catch {
            print("[FnKeyMonitor] Failed to parse hidutil mappings: \(error)")
            return nil
        }
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
            print("[FnKeyMonitor] Failed to launch hidutil: \(error)")
            return nil
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        guard task.terminationStatus == 0 else {
            if let message = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                print("[FnKeyMonitor] hidutil failed: \(message)")
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
        guard triggerMode == .nativeFn,
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
        switch triggerMode {
        case .remappedF18:
            return handleRemappedF18(event, type: type)
        case .nativeFn:
            return handleNativeFn(event, type: type)
        }
    }

    private func handleRemappedF18(_ event: CGEvent, type: CGEventType) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keycode == Self.remappedF18KeyCode else { return false }

        if type == .keyDown && !fnIsDown {
            fnIsDown = true
            DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
            return true
        } else if type == .keyUp && fnIsDown {
            fnIsDown = false
            DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
            return true
        }

        return true
    }

    private func handleNativeFn(_ event: CGEvent, type: CGEventType) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if keycode == Self.nativeFnGlobeKeyCode {
            if type == .keyDown && !fnIsDown {
                fnIsDown = true
                saveCurrentInputSource()
                DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
                return true
            } else if type == .keyUp && fnIsDown {
                fnIsDown = false
                restoreInputSourceIfNeeded()
                DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
                return true
            }
            return true
        }

        if type == .flagsChanged {
            let isFnPressed = flags.contains(.maskSecondaryFn)
            if isFnPressed && !fnIsDown {
                fnIsDown = true
                saveCurrentInputSource()
                DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
                return true
            } else if !isFnPressed && fnIsDown {
                fnIsDown = false
                restoreInputSourceIfNeeded()
                DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
                return true
            }
        }

        return false
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
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
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

    let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let shouldSuppress = monitor.handleEvent(event, type: type)

    if shouldSuppress {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
