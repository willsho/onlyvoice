import Cocoa
import Carbon
import ApplicationServices

/// Monitors Fn key press/release globally via CGEvent tap.
/// Suppresses the Fn event to prevent triggering the emoji picker.
final class FnKeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnIsDown = false

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

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        // We need to pass self to the C callback, so use Unmanaged
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

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

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
    }

    fileprivate func handleFlagsChanged(_ event: CGEvent) -> Bool {
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

    guard type == .flagsChanged, let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let shouldSuppress = monitor.handleFlagsChanged(event)

    if shouldSuppress {
        return nil  // Suppress the event — prevents emoji picker
    }
    return Unmanaged.passUnretained(event)
}
