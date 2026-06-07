import Cocoa

/// Settings window: 选择服务商并配置各自的 API Key 与模型。
final class SettingsWindowController: NSWindowController {
    private var providerPopup: NSPopUpButton!
    private var apiKeyField: NSSecureTextField!
    private var apiKeyPlainField: NSTextField!
    private var revealButton: NSButton!
    private var apiKeyRevealed = false
    private var modelField: NSComboBox!
    private var statusLabel: NSTextField!
    private var testButton: NSButton!
    private var saveButton: NSButton!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "OnlyVoice Settings"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        setupUI()
        loadSettings()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let padding: CGFloat = 20
        let labelWidth: CGFloat = 80
        let fieldHeight: CGFloat = 28
        let fieldX = padding + labelWidth + 8
        let fieldWidth: CGFloat = 318

        // Provider label + popup
        let providerLabel = NSTextField(labelWithString: "Provider:")
        providerLabel.frame = NSRect(x: padding, y: 205, width: labelWidth, height: 18)
        providerLabel.alignment = .right
        providerLabel.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(providerLabel)

        providerPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: 200, width: 350, height: fieldHeight), pullsDown: false)
        for provider in RealtimeProvider.allCases {
            providerPopup.addItem(withTitle: provider.displayName)
            providerPopup.lastItem?.representedObject = provider.rawValue
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        contentView.addSubview(providerPopup)

        // API Key label
        let apiKeyLabel = NSTextField(labelWithString: "API Key:")
        apiKeyLabel.frame = NSRect(x: padding, y: 165, width: labelWidth, height: 18)
        apiKeyLabel.alignment = .right
        apiKeyLabel.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(apiKeyLabel)

        // API Key field (secure) and plain field overlay for reveal toggle
        apiKeyField = NSSecureTextField(frame: NSRect(x: fieldX, y: 160, width: fieldWidth, height: fieldHeight))
        apiKeyField.placeholderString = "Enter your API Key"
        apiKeyField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        contentView.addSubview(apiKeyField)

        apiKeyPlainField = NSTextField(frame: NSRect(x: fieldX, y: 160, width: fieldWidth, height: fieldHeight))
        apiKeyPlainField.placeholderString = "Enter your API Key"
        apiKeyPlainField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        apiKeyPlainField.isHidden = true
        contentView.addSubview(apiKeyPlainField)

        // Reveal (eye) toggle button
        revealButton = NSButton(frame: NSRect(x: fieldX + fieldWidth + 4, y: 160, width: 28, height: fieldHeight))
        revealButton.bezelStyle = .regularSquare
        revealButton.isBordered = false
        revealButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show API Key")
        revealButton.target = self
        revealButton.action = #selector(toggleRevealAPIKey)
        revealButton.toolTip = "Show/Hide API Key"
        contentView.addSubview(revealButton)

        // Model label
        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.frame = NSRect(x: padding, y: 125, width: labelWidth, height: 18)
        modelLabel.alignment = .right
        modelLabel.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(modelLabel)

        // Model field
        modelField = NSComboBox(frame: NSRect(x: fieldX, y: 120, width: 350, height: fieldHeight))
        modelField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        modelField.isEditable = true
        modelField.completes = true
        contentView.addSubview(modelField)

        // Status label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: padding, y: 75, width: 440, height: 30)
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        contentView.addSubview(statusLabel)

        // Test button
        testButton = NSButton(title: "Test", target: self, action: #selector(testConnection))
        testButton.frame = NSRect(x: 280, y: 30, width: 80, height: 32)
        testButton.bezelStyle = .rounded
        contentView.addSubview(testButton)

        // Save button
        saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.frame = NSRect(x: 370, y: 30, width: 80, height: 32)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)
    }

    private func selectedProvider() -> RealtimeProvider {
        if let raw = providerPopup.selectedItem?.representedObject as? String,
           let provider = RealtimeProvider(rawValue: raw) {
            return provider
        }
        return .dashscope
    }

    @objc private func providerChanged() {
        // 切换服务商：丢弃未保存的编辑，载入目标服务商已存的配置。
        apiKeyRevealed = false
        apiKeyField.isHidden = false
        apiKeyPlainField.isHidden = true
        revealButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show API Key")
        loadSettings(for: selectedProvider())
        statusLabel.stringValue = ""
    }

    @objc private func toggleRevealAPIKey() {
        apiKeyRevealed.toggle()
        if apiKeyRevealed {
            apiKeyPlainField.stringValue = apiKeyField.stringValue
            apiKeyField.isHidden = true
            apiKeyPlainField.isHidden = false
            revealButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Hide API Key")
        } else {
            apiKeyField.stringValue = apiKeyPlainField.stringValue
            apiKeyPlainField.isHidden = true
            apiKeyField.isHidden = false
            revealButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show API Key")
        }
    }

    private func currentAPIKey() -> String {
        (apiKeyRevealed ? apiKeyPlainField.stringValue : apiKeyField.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadSettings() {
        let current = RealtimeProvider.current
        providerPopup.selectItem(withTitle: current.displayName)
        loadSettings(for: current)
    }

    private func loadSettings(for provider: RealtimeProvider) {
        let defaults = UserDefaults.standard
        let key = defaults.string(forKey: provider.apiKeyDefaultsKey) ?? ""
        apiKeyField.stringValue = key
        apiKeyPlainField.stringValue = key

        modelField.removeAllItems()
        modelField.addItems(withObjectValues: provider.models)
        modelField.numberOfVisibleItems = provider.models.count
        modelField.placeholderString = provider.defaultModel
        let model = defaults.string(forKey: provider.modelDefaultsKey) ?? provider.defaultModel
        addModelToDropdownIfNeeded(model)
        modelField.stringValue = model
    }

    @objc private func saveSettings() {
        let defaults = UserDefaults.standard
        let provider = selectedProvider()

        defaults.set(currentAPIKey(), forKey: provider.apiKeyDefaultsKey)

        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(model.isEmpty ? provider.defaultModel : model, forKey: provider.modelDefaultsKey)

        // 保存即启用所选服务商，并通知状态栏菜单同步勾选。
        defaults.set(provider.rawValue, forKey: RealtimeProvider.selectionKey)
        NotificationCenter.default.post(name: .realtimeProviderChanged, object: nil)

        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = "Settings saved. Using \(provider.displayName)."

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.window?.close()
        }
    }

    @objc private func testConnection() {
        let provider = selectedProvider()
        let apiKey = currentAPIKey()
        guard !apiKey.isEmpty else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "API Key is empty."
            return
        }

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Testing connection..."
        testButton.isEnabled = false

        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = model.isEmpty ? provider.defaultModel : model

        // Test via Realtime WebSocket handshake.
        let encodedModel = modelName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? modelName
        let urlString = "\(provider.endpoint)?model=\(encodedModel)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: request)
        ws.resume()

        // Try to receive a message (session.created) within 5 seconds
        ws.receive { [weak self] result in
            DispatchQueue.main.async {
                self?.testButton.isEnabled = true
                switch result {
                case .success(let message):
                    var responseText = ""
                    switch message {
                    case .string(let text): responseText = text
                    case .data(let data): responseText = String(data: data, encoding: .utf8) ?? ""
                    @unknown default: break
                    }

                    if responseText.contains("session.created") {
                        self?.statusLabel.textColor = .systemGreen
                        self?.statusLabel.stringValue = "Connection successful! Model: \(modelName)"
                    } else if responseText.contains("error") {
                        self?.statusLabel.textColor = .systemRed
                        self?.statusLabel.stringValue = "Error: \(responseText.prefix(200))"
                    } else {
                        self?.statusLabel.textColor = .systemOrange
                        self?.statusLabel.stringValue = "Unexpected response: \(responseText.prefix(200))"
                    }

                case .failure(let error):
                    self?.statusLabel.textColor = .systemRed
                    self?.statusLabel.stringValue = "Connection failed: \(error.localizedDescription)"
                }

                ws.cancel(with: .normalClosure, reason: nil)
                session.invalidateAndCancel()
            }
        }
    }

    private func addModelToDropdownIfNeeded(_ model: String) {
        guard !model.isEmpty, modelField.indexOfItem(withObjectValue: model) == NSNotFound else { return }
        modelField.addItem(withObjectValue: model)
    }

    func showWindow() {
        loadSettings()
        statusLabel.stringValue = ""
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
