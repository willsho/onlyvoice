import Cocoa
import Carbon
import ApplicationServices
import IOKit.hid
import IOKit.hidsystem

/// Monitors Fn/Globe press/release globally.
/// Prefers remapping Fn/Globe to an inert surrogate key so macOS doesn't switch input sources.
final class FnKeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnIsDown = false
    private var eventSystemClient: IOHIDEventSystemClient?
    private var originalGlobalMapping: Any?
    private var sigTermSource: DispatchSourceSignal?

    /// Static state for atexit / signal cleanup — ensures Fn remapping is restored
    /// even if the process exits without calling stop() (crash, exit(), SIGTERM).
    /// SIGKILL (kill -9) cannot be caught; the next launch cleans up via installFnRemapping
    /// which filters out stale Fn entries before re-adding its own.
    private static var pendingCleanup: (system: IOHIDEventSystemClient, original: Any?)?
    private static var atexitRegistered = false

    private let remappedKeyCode = CGKeyCode(kVK_F18)
    private let fnUsageValue: UInt64 = 0x000000FF00000003
    private let remappedUsageValue: UInt64 = 0x00070000006D

    /// Prompts the user to grant Accessibility permission if not already granted.
    /// Returns true if the process is trusted.
    @discardableResult
    func ensureAccessibilityPermission(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [key: prompt]
        return AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        // Request Accessibility permission on first launch (needed for event tap + text injection).
        if !ensureAccessibilityPermission(prompt: true) {
            print("[FnKeyMonitor] Accessibility permission not granted yet. System prompt shown; user must enable OnlyVoice in System Settings → Privacy & Security → Accessibility, then relaunch.")
            return
        }

        let remapInstalled = installFnRemapping()
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        // We need to pass self to the C callback, so use Unmanaged
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Once Fn/Globe is remapped to F18, a regular session-level tap is sufficient.
        // Keep flagsChanged in the mask as a fallback path when remapping isn't available.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,  // Active tap so we can suppress events
            eventsOfInterest: eventMask,
            callback: fnKeyCallback,
            userInfo: selfPtr
        ) else {
            print("[FnKeyMonitor] Failed to create event tap. Check Accessibility permissions.")
            return
        }

        if !remapInstalled {
            print("[FnKeyMonitor] Fn remapping unavailable; falling back to flagsChanged monitoring.")
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        setupSigTermHandler()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        fnIsDown = false
        tearDownSigTermHandler()
        restoreFnRemapping()
    }

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        if eventSystemClient != nil, handleRemappedKeyEvent(type: type, event: event) {
            return true
        }

        guard type == .flagsChanged else {
            return false
        }

        let flags = event.flags
        let isFnPressed = flags.contains(.maskSecondaryFn)

        if isFnPressed && !fnIsDown {
            fnIsDown = true
            DispatchQueue.main.async { [weak self] in
                self?.onFnDown?()
            }
            return true  // suppress
        } else if !isFnPressed && fnIsDown {
            fnIsDown = false
            DispatchQueue.main.async { [weak self] in
                self?.onFnUp?()
            }
            return true  // suppress
        }

        return false  // don't suppress non-Fn flag changes
    }

    private func handleRemappedKeyEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown || type == .keyUp else {
            return false
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == remappedKeyCode else {
            return false
        }

        if type == .keyDown {
            let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            guard !isAutoRepeat, !fnIsDown else { return true }
            fnIsDown = true
            DispatchQueue.main.async { [weak self] in
                self?.onFnDown?()
            }
            return true
        }

        guard fnIsDown else { return true }
        fnIsDown = false
        DispatchQueue.main.async { [weak self] in
            self?.onFnUp?()
        }
        return true
    }

    private func installFnRemapping() -> Bool {
        restoreFnRemapping()

        let system = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        self.eventSystemClient = system

        let originalMapping = IOHIDEventSystemClientCopyProperty(system, kIOHIDUserKeyUsageMapKey as CFString)
        let existingMappings = (originalMapping as? [[String: NSNumber]]) ?? []
        var updatedMappings = existingMappings.filter {
            $0[kIOHIDKeyboardModifierMappingSrcKey]?.uint64Value != fnUsageValue
        }
        updatedMappings.append([
            kIOHIDKeyboardModifierMappingSrcKey: NSNumber(value: fnUsageValue),
            kIOHIDKeyboardModifierMappingDstKey: NSNumber(value: remappedUsageValue)
        ])

        guard IOHIDEventSystemClientSetProperty(system, kIOHIDUserKeyUsageMapKey as CFString, updatedMappings as CFArray) else {
            self.eventSystemClient = nil
            return false
        }

        self.originalGlobalMapping = originalMapping

        // Register atexit handler so Fn mapping is restored even on abnormal exit.
        Self.pendingCleanup = (system: system, original: originalMapping)
        if !Self.atexitRegistered {
            Self.atexitRegistered = true
            atexit { FnKeyMonitor.atexitCleanup() }
        }
        return true
    }

    private func restoreFnRemapping() {
        guard let system = eventSystemClient else { return }

        if let originalGlobalMapping {
            _ = IOHIDEventSystemClientSetProperty(system, kIOHIDUserKeyUsageMapKey as CFString, originalGlobalMapping as CFTypeRef)
        } else {
            _ = IOHIDEventSystemClientSetProperty(system, kIOHIDUserKeyUsageMapKey as CFString, [] as CFArray)
        }

        originalGlobalMapping = nil
        eventSystemClient = nil
        Self.pendingCleanup = nil
    }

    // MARK: - Process termination safety

    /// Catch SIGTERM (Force Quit / kill) so we can restore Fn before the process dies.
    private func setupSigTermHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.stop()
            exit(0)
        }
        source.resume()
        sigTermSource = source
    }

    private func tearDownSigTermHandler() {
        sigTermSource?.cancel()
        sigTermSource = nil
        signal(SIGTERM, SIG_DFL)
    }

    /// Called by atexit — last-resort restoration when stop() was never invoked.
    private static func atexitCleanup() {
        guard let info = pendingCleanup else { return }
        if let original = info.original {
            _ = IOHIDEventSystemClientSetProperty(info.system, kIOHIDUserKeyUsageMapKey as CFString, original as CFTypeRef)
        } else {
            _ = IOHIDEventSystemClientSetProperty(info.system, kIOHIDUserKeyUsageMapKey as CFString, [] as CFArray)
        }
        pendingCleanup = nil
    }
}

/// C callback for CGEvent tap
private func fnKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Handle tap disabled events (system can disable taps under load)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let shouldSuppress = monitor.handleEvent(type: type, event: event)

    if shouldSuppress {
        return nil  // Suppress the surrogate event (or legacy Fn flagsChanged fallback)
    }
    return Unmanaged.passUnretained(event)
}
