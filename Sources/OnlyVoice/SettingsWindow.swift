import Cocoa

/// Settings window for configuring DashScope API Key and Model.
final class SettingsWindowController: NSWindowController {
    private var apiKeyField: NSSecureTextField!
    private var modelField: NSComboBox!
    private var statusLabel: NSTextField!
    private var testButton: NSButton!
    private var saveButton: NSButton!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Qwen-Omni Settings"
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

        // API Key label
        let apiKeyLabel = NSTextField(labelWithString: "API Key:")
        apiKeyLabel.frame = NSRect(x: padding, y: 160, width: labelWidth, height: fieldHeight)
        apiKeyLabel.alignment = .right
        apiKeyLabel.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(apiKeyLabel)

        // API Key field (secure but allow clearing)
        apiKeyField = NSSecureTextField(frame: NSRect(x: padding + labelWidth + 8, y: 160, width: 350, height: fieldHeight))
        apiKeyField.placeholderString = "Enter your DashScope API Key"
        apiKeyField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        contentView.addSubview(apiKeyField)

        // Model label
        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.frame = NSRect(x: padding, y: 120, width: labelWidth, height: fieldHeight)
        modelLabel.alignment = .right
        modelLabel.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(modelLabel)

        // Model field
        modelField = NSComboBox(frame: NSRect(x: padding + labelWidth + 8, y: 120, width: 350, height: fieldHeight))
        modelField.placeholderString = DashScopeRealtimeDefaults.model
        modelField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        modelField.isEditable = true
        modelField.completes = true
        modelField.numberOfVisibleItems = DashScopeRealtimeDefaults.models.count
        modelField.addItems(withObjectValues: DashScopeRealtimeDefaults.models)
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

    private func loadSettings() {
        let defaults = UserDefaults.standard
        apiKeyField.stringValue = defaults.string(forKey: "dashscope_api_key") ?? ""
        let model = defaults.string(forKey: "dashscope_model") ?? DashScopeRealtimeDefaults.model
        addModelToDropdownIfNeeded(model)
        modelField.stringValue = model
    }

    @objc private func saveSettings() {
        let defaults = UserDefaults.standard
        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(apiKey, forKey: "dashscope_api_key")

        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(model.isEmpty ? DashScopeRealtimeDefaults.model : model, forKey: "dashscope_model")

        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = "Settings saved."

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.window?.close()
        }
    }

    @objc private func testConnection() {
        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "API Key is empty."
            return
        }

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Testing connection..."
        testButton.isEnabled = false

        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = model.isEmpty ? DashScopeRealtimeDefaults.model : model

        // Test via Realtime WebSocket handshake.
        let encodedModel = modelName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? modelName
        let urlString = "\(DashScopeRealtimeDefaults.endpoint)?model=\(encodedModel)"
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
