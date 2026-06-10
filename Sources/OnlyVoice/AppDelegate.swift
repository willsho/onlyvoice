import Cocoa
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let audioEngine = AudioEngine()
    private let realtimeClient = RealtimeClient()
    private let hotkeyMonitor = HotkeyMonitor()
    private let capsulePanel = CapsulePanel()
    private let textInjector = TextInjector()
    private var providerMenu: NSMenu?
    private var languageMenu: NSMenu?

    private var isRecording = false
    private var pendingTranscript = ""
    private var waitingForResponse = false
    /// 录音中已自动重连次数（避免无限循环）。
    private var recordingReconnectCount = 0
    /// 已提交后等待响应阶段的自动重试次数。
    private var responseReconnectCount = 0

    // Recording mode: tap-to-toggle, optionally hold-to-talk.
    // - Press hotkey → startRecording, enter .holding
    // - Release quickly (< tapThreshold) → stay recording in .toggled
    // - Release after long hold → stopRecording (only when hold-to-record is enabled)
    // - Next hotkey press while .toggled → stopRecording
    private enum RecordMode { case idle, holding, toggled }
    private var recordMode: RecordMode = .idle
    private var hotkeyDownAt: CFTimeInterval = 0
    private let tapThreshold: CFTimeInterval = 0.4
    static let holdToRecordKey = "hold_to_record_enabled"

    private let startSound = AppDelegate.loadSound(named: "record-start")
    private let endSound = AppDelegate.loadSound(named: "record-end")

    // Language options
    private let languages: [(code: String, name: String)] = [
        ("zh-CN", "简体中文"),
        ("zh-TW", "繁體中文"),
        ("en-US", "English"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
    ]

    private static func loadSound(named name: String) -> NSSound? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        return NSSound(contentsOf: url, byReference: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register defaults
        UserDefaults.standard.register(defaults: [
            "selected_language": "zh-CN",
            Self.holdToRecordKey: false,
            RealtimeProvider.selectionKey: RealtimeProvider.dashscope.rawValue,
            RealtimeProvider.dashscope.modelDefaultsKey: RealtimeProvider.dashscope.defaultModel,
            RealtimeProvider.stepfun.modelDefaultsKey: RealtimeProvider.stepfun.defaultModel
        ])
        migrateDefaultModelIfNeeded()

        setupMainMenu()
        setupStatusBar()
        setupHotkeyMonitor()
        setupRealtimeCallbacks()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshProviderMenuState),
            name: .realtimeProviderChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshLanguageMenuState),
            name: .spokenLanguageChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(hotkeyCaptureStateChanged(_:)),
            name: .hotkeyCaptureStateChanged, object: nil)
        requestMicrophonePermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor.stop()
    }

    // MARK: - Status Bar

    private func migrateDefaultModelIfNeeded() {
        let defaults = UserDefaults.standard
        let key = RealtimeProvider.dashscope.modelDefaultsKey
        let previousDefaults = [
            "qwen3.5-omni-plus-realtime",
            "qwen3-omni-flash-realtime"
        ]
        if let model = defaults.string(forKey: key), previousDefaults.contains(model) {
            defaults.set(RealtimeProvider.dashscope.defaultModel, forKey: key)
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = Self.statusBarIcon(active: false)
        }

        let menu = NSMenu()

        // Service provider submenu (DashScope / StepFun)
        let providerItem = NSMenuItem(title: "Service Provider", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu()
        let currentProvider = RealtimeProvider.current
        for provider in RealtimeProvider.allCases {
            let item = NSMenuItem(title: provider.displayName, action: #selector(selectProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = provider.rawValue
            if provider == currentProvider {
                item.state = .on
            }
            providerMenu.addItem(item)
        }
        providerItem.submenu = providerMenu
        self.providerMenu = providerMenu
        menu.addItem(providerItem)

        // Spoken language submenu (the language the user speaks, not the system UI language)
        let langItem = NSMenuItem(title: "Spoken Language", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        let currentLang = UserDefaults.standard.string(forKey: "selected_language") ?? "zh-CN"

        for lang in languages {
            let item = NSMenuItem(title: lang.name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            if lang.code == currentLang {
                item.state = .on
            }
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        self.languageMenu = langMenu
        menu.addItem(langItem)

        menu.addItem(.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // About
        let aboutItem = NSMenuItem(title: "About OnlyVoice", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit OnlyVoice", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: RealtimeProvider.selectionKey)

        // Update menu checkmarks
        if let providerMenu = sender.menu {
            for item in providerMenu.items {
                item.state = (item.representedObject as? String) == raw ? .on : .off
            }
        }
    }

    /// 设置窗口切换了 provider，同步状态栏子菜单勾选。
    @objc private func refreshProviderMenuState() {
        let raw = RealtimeProvider.current.rawValue
        providerMenu?.items.forEach { item in
            item.state = (item.representedObject as? String) == raw ? .on : .off
        }
    }

    /// 设置窗口切换了口语语言，同步状态栏子菜单勾选。
    @objc private func refreshLanguageMenuState() {
        let code = UserDefaults.standard.string(forKey: "selected_language") ?? "zh-CN"
        languageMenu?.items.forEach { item in
            item.state = (item.representedObject as? String) == code ? .on : .off
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: "selected_language")

        // Update menu checkmarks
        if let langMenu = sender.menu {
            for item in langMenu.items {
                item.state = (item.representedObject as? String) == code ? .on : .off
            }
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.show()
    }

    @objc private func showAbout() {
        SettingsWindowController.show(tab: .about)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Hotkey Monitor

    private func setupHotkeyMonitor() {
        hotkeyMonitor.onHotkeyDown = { [weak self] in
            self?.handleHotkeyDown()
        }
        hotkeyMonitor.onHotkeyUp = { [weak self] in
            self?.handleHotkeyUp()
        }
        hotkeyMonitor.onPermissionRequired = { [weak self] in
            self?.updateStatusIcon(permissionNeeded: true)
        }
        hotkeyMonitor.onPermissionGranted = { [weak self] in
            self?.updateStatusIcon(permissionNeeded: false)
        }
        hotkeyMonitor.start()
    }

    /// 设置界面录制快捷键期间暂停全局监听，避免按键被当作录音触发。
    @objc private func hotkeyCaptureStateChanged(_ note: Notification) {
        if (note.userInfo?["capturing"] as? Bool) == true {
            hotkeyMonitor.suspendMonitoring()
        } else {
            hotkeyMonitor.resumeMonitoring()
        }
    }

    // MARK: - Realtime Callbacks

    private func setupRealtimeCallbacks() {
        realtimeClient.onTranscript = { [weak self] text in
            self?.pendingTranscript = text
            self?.capsulePanel.updateTranscript(text)
        }

        realtimeClient.onFinalTranscript = { [weak self] text in
            guard let self = self else { return }
            self.waitingForResponse = false
            self.responseReconnectCount = 0
            self.pendingTranscript = text

            // Hide panel then inject text
            self.capsulePanel.hide { [weak self] in
                guard let self = self else { return }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.textInjector.inject(text)
                }
                self.realtimeClient.disconnect()
            }
            self.updateStatusIcon(recording: false)
        }

        realtimeClient.onError = { [weak self] error in
            print("[OnlyVoice] Error: \(error)")
            guard let self = self else { return }

            // 录音中出错：不要撕掉 UI 让用户白说话；尝试静默重连一次，整轮录音会在
            // RealtimeClient 中保留，并在新 session 就绪后重放。重连次数有限。
            if self.isRecording && self.recordingReconnectCount < 2 {
                self.recordingReconnectCount += 1
                print("[OnlyVoice] mid-recording error, reconnecting (attempt \(self.recordingReconnectCount))")
                self.capsulePanel.updateTranscript("Reconnecting...")
                self.realtimeClient.connect(preserveCurrentTurn: true)
                return
            }

            if self.waitingForResponse && self.responseReconnectCount < 1 {
                self.responseReconnectCount += 1
                print("[OnlyVoice] response-stage error, retrying (attempt \(self.responseReconnectCount))")
                self.capsulePanel.updateTranscript("Retrying transcription...")
                self.realtimeClient.connect(preserveCurrentTurn: true)
                return
            }

            self.waitingForResponse = false
            self.responseReconnectCount = 0
            self.capsulePanel.updateTranscript("⚠ \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.capsulePanel.hide()
                self.realtimeClient.disconnect()
            }
            self.updateStatusIcon(recording: false)
        }
    }

    // MARK: - Recording

    private func handleHotkeyDown() {
        switch recordMode {
        case .idle:
            hotkeyDownAt = CACurrentMediaTime()
            recordMode = .holding
            startRecording()
        case .toggled:
            // Second tap ends the toggled session.
            recordMode = .idle
            stopRecording()
        case .holding:
            break // shouldn't happen (hotkey already down)
        }
    }

    private func handleHotkeyUp() {
        switch recordMode {
        case .holding:
            let held = CACurrentMediaTime() - hotkeyDownAt
            let holdEnabled = UserDefaults.standard.bool(forKey: Self.holdToRecordKey)
            if holdEnabled && held >= tapThreshold {
                // Hold-to-record: releasing after a long hold stops recording.
                recordMode = .idle
                stopRecording()
            } else {
                // Tap (or hold-to-record disabled): keep recording until next press.
                recordMode = .toggled
            }
        case .toggled, .idle:
            break
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        pendingTranscript = ""
        recordingReconnectCount = 0
        responseReconnectCount = 0
        waitingForResponse = false

        startSound?.stop()
        startSound?.play()

        updateStatusIcon(recording: true)
        capsulePanel.show()

        // Connect to the realtime service and start audio
        realtimeClient.connect()

        audioEngine.onRMSLevel = { [weak self] rms in
            self?.capsulePanel.updateRMS(rms)
        }

        audioEngine.onAudioData = { [weak self] base64Audio in
            self?.realtimeClient.sendAudioData(base64Audio)
        }

        do {
            try audioEngine.start()
        } catch {
            print("[OnlyVoice] Audio engine start failed: \(error)")
            capsulePanel.updateTranscript("⚠ Microphone error")
            isRecording = false
            updateStatusIcon(recording: false)
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordMode = .idle

        audioEngine.stop()
        endSound?.stop()
        endSound?.play()
        responseReconnectCount = 0

        guard realtimeClient.hasBufferedAudio else {
            capsulePanel.updateTranscript("⚠ No audio captured")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.capsulePanel.hide()
                self?.realtimeClient.disconnect()
                self?.updateStatusIcon(recording: false)
            }
            return
        }

        waitingForResponse = true
        realtimeClient.commitAudioBuffer()

        // Update UI to show "processing"
        capsulePanel.updateRMS(0)
        if pendingTranscript.isEmpty {
            capsulePanel.updateTranscript("Processing...")
        }

        // Timeout: if no response in 10 seconds, hide and cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self = self, self.waitingForResponse else { return }
            self.waitingForResponse = false
            self.responseReconnectCount = 0
            self.capsulePanel.updateTranscript("⚠ Transcription timed out")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.capsulePanel.hide()
                self.realtimeClient.disconnect()
                self.updateStatusIcon(recording: false)
            }
        }
    }

    private func updateStatusIcon(recording: Bool) {
        if let button = statusItem.button {
            button.image = Self.statusBarIcon(active: recording)
            button.toolTip = "OnlyVoice"
        }
    }

    private func updateStatusIcon(permissionNeeded: Bool) {
        guard let button = statusItem.button else { return }
        if permissionNeeded {
            button.image = Self.statusBarIcon(active: false, needsPermission: true)
            button.toolTip = "OnlyVoice: Accessibility permission required — enable in System Settings → Privacy & Security → Accessibility"
        } else {
            button.image = Self.statusBarIcon(active: false)
            button.toolTip = "OnlyVoice"
        }
    }

    /// 状态栏模板图标：呼应 app icon 的「圆角屏 + 波形」造型。
    /// active=true（录音中）时波形满振幅；needsPermission=true 时屏内画感叹号，
    /// 提示辅助功能未授权。isTemplate 让系统自动适配深/浅色菜单栏。
    static func statusBarIcon(active: Bool, needsPermission: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let frame = rect.insetBy(dx: 1.5, dy: 1.5)
            let radius = frame.width * 0.3
            let body = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
            body.lineWidth = 1.4
            NSColor.black.setStroke()
            body.stroke()

            NSColor.black.setFill()

            if needsPermission {
                // 屏内感叹号：竖条 + 圆点，明确提示「未授权 / 需注意」。
                let barWidth: CGFloat = 1.6
                let inset = frame.height * 0.24
                let dotSize: CGFloat = 1.8
                let dotGap: CGFloat = 1.7
                let dotBottom = frame.minY + inset
                let barBottom = dotBottom + dotSize + dotGap
                let barTop = frame.maxY - inset
                let barRect = NSRect(x: rect.midX - barWidth / 2, y: barBottom,
                                     width: barWidth, height: barTop - barBottom)
                NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                let dotRect = NSRect(x: rect.midX - dotSize / 2, y: dotBottom,
                                     width: dotSize, height: dotSize)
                NSBezierPath(ovalIn: dotRect).fill()
                return true
            }

            let bars: [CGFloat] = active
                ? [0.5, 0.8, 1.0, 0.8, 0.5]
                : [0.34, 0.58, 0.78, 0.58, 0.34]
            let barWidth: CGFloat = 1.3
            let gap: CGFloat = 1.4
            let maxHeight = frame.height * 0.5
            let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
            var x = rect.midX - totalWidth / 2
            for ratio in bars {
                let h = maxHeight * ratio
                let barRect = NSRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h)
                NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Permissions

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Microphone Access Required"
                    alert.informativeText = "OnlyVoice needs microphone access for voice input. Please enable it in System Settings > Privacy & Security > Microphone."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open Settings")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            }
        }
    }
}
