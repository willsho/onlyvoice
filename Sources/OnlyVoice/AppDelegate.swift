import Cocoa
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let audioEngine = AudioEngine()
    private let qwenClient = QwenRealtimeClient()
    private let fnMonitor = FnKeyMonitor()
    private let capsulePanel = CapsulePanel()
    private let textInjector = TextInjector()
    private var settingsController: SettingsWindowController?

    private var isRecording = false
    private var pendingTranscript = ""
    private var waitingForResponse = false

    private let startSound: NSSound? = {
        guard let url = Bundle.module.url(forResource: "record-start", withExtension: "wav") else { return nil }
        return NSSound(contentsOf: url, byReference: true)
    }()
    private let endSound: NSSound? = {
        guard let url = Bundle.module.url(forResource: "record-end", withExtension: "wav") else { return nil }
        return NSSound(contentsOf: url, byReference: true)
    }()

    // Language options
    private let languages: [(code: String, name: String)] = [
        ("zh-CN", "简体中文"),
        ("zh-TW", "繁體中文"),
        ("en-US", "English"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register defaults
        UserDefaults.standard.register(defaults: [
            "selected_language": "zh-CN",
            "dashscope_model": DashScopeRealtimeDefaults.model
        ])
        migrateDefaultModelIfNeeded()

        setupMainMenu()
        setupStatusBar()
        setupFnMonitor()
        setupQwenCallbacks()
        requestMicrophonePermission()
    }

    // MARK: - Status Bar

    private func migrateDefaultModelIfNeeded() {
        let defaults = UserDefaults.standard
        let previousDefaults = [
            "qwen3.5-omni-plus-realtime",
            "qwen3-omni-flash-realtime"
        ]
        if let model = defaults.string(forKey: "dashscope_model"), previousDefaults.contains(model) {
            defaults.set(DashScopeRealtimeDefaults.model, forKey: "dashscope_model")
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
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "OnlyVoice")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        let menu = NSMenu()

        // Language submenu
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
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
        menu.addItem(langItem)

        menu.addItem(.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Qwen-Omni Settings...", action: #selector(openSettings), keyEquivalent: ",")
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
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        settingsController?.showWindow()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "OnlyVoice"
        alert.informativeText = "Voice-to-text input for macOS.\nHold Fn to record, release to transcribe.\n\nPowered by Qwen-Omni-Realtime."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Fn Key Monitor

    private func setupFnMonitor() {
        fnMonitor.onFnDown = { [weak self] in
            self?.startRecording()
        }
        fnMonitor.onFnUp = { [weak self] in
            self?.stopRecording()
        }
        fnMonitor.start()
    }

    // MARK: - Qwen Callbacks

    private func setupQwenCallbacks() {
        qwenClient.onTranscript = { [weak self] text in
            self?.pendingTranscript = text
            self?.capsulePanel.updateTranscript(text)
        }

        qwenClient.onFinalTranscript = { [weak self] text in
            guard let self = self else { return }
            self.waitingForResponse = false
            self.pendingTranscript = text

            // Hide panel then inject text
            self.capsulePanel.hide { [weak self] in
                guard let self = self else { return }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.textInjector.inject(text)
                }
                self.qwenClient.disconnect()
            }
            self.updateStatusIcon(recording: false)
        }

        qwenClient.onError = { [weak self] error in
            print("[OnlyVoice] Error: \(error)")
            guard let self = self else { return }
            self.waitingForResponse = false
            self.capsulePanel.updateTranscript("⚠ \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.capsulePanel.hide()
                self.qwenClient.disconnect()
            }
            self.updateStatusIcon(recording: false)
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        pendingTranscript = ""

        startSound?.stop()
        startSound?.play()

        updateStatusIcon(recording: true)
        capsulePanel.show()

        // Connect to Qwen and start audio
        qwenClient.connect()

        audioEngine.onRMSLevel = { [weak self] rms in
            self?.capsulePanel.updateRMS(rms)
        }

        audioEngine.onAudioData = { [weak self] base64Audio in
            self?.qwenClient.sendAudioData(base64Audio)
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

        audioEngine.stop()
        endSound?.stop()
        endSound?.play()
        qwenClient.commitAudioBuffer()
        waitingForResponse = true

        // Update UI to show "processing"
        capsulePanel.updateRMS(0)
        if pendingTranscript.isEmpty {
            capsulePanel.updateTranscript("Processing...")
        }

        // Timeout: if no response in 10 seconds, hide and cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self = self, self.waitingForResponse else { return }
            self.waitingForResponse = false
            self.capsulePanel.hide()
            self.qwenClient.disconnect()
            self.updateStatusIcon(recording: false)
        }
    }

    private func updateStatusIcon(recording: Bool) {
        if let button = statusItem.button {
            let symbolName = recording ? "waveform.circle.fill" : "waveform"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "OnlyVoice")
            button.image?.size = NSSize(width: 18, height: 18)
        }
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
