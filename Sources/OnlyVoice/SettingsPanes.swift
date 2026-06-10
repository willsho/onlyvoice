import AppKit
import Observation
import SwiftUI

// MARK: - General (recording hotkey + spoken language)

struct GeneralSettingsPane: View {
    @AppStorage("selected_language") private var language = "zh-CN"
    @AppStorage(AppDelegate.holdToRecordKey) private var holdToRecord = false

    private let languages: [(code: String, name: String)] = [
        ("zh-CN", "简体中文"),
        ("zh-TW", "繁體中文"),
        ("en-US", "English"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent("Shortcut") {
                    HotkeyRecorderField()
                }
                Toggle("Hold to record", isOn: $holdToRecord)
            } header: {
                Text("Recording")
            } footer: {
                Text("Tap the shortcut to start recording, tap again to stop. With \"Hold to record\" on, holding the shortcut records until you release it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Spoken Language", selection: $language) {
                    ForEach(languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Transcription")
            } footer: {
                Text("The language you speak when dictating — not the app's interface language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onChange(of: language) { _, _ in
            NotificationCenter.default.post(name: .spokenLanguageChanged, object: nil)
        }
    }
}

// MARK: - Hotkey recorder

/// 录音快捷键录制控件：点击进入捕获态，按下目标键完成设置，Esc 取消。
/// 捕获期间通过 .hotkeyCaptureStateChanged 通知 HotkeyMonitor 暂停全局匹配。
/// 注意：当前快捷键为 Fn 时系统层 remap（Fn→F18）仍然生效，
/// 此时按 Fn 会以 F18(79) keyDown 的形式到达，需要识别回 Fn。
struct HotkeyRecorderField: View {
    @State private var hotkey = RecordingHotkey.current
    @State private var capturing = false
    @State private var hint: String?
    @State private var eventMonitor: Any?
    @State private var pendingModifierKeyCode: Int64?

    var body: some View {
        HStack(spacing: 8) {
            if let hint, capturing {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !capturing && hotkey != .fn {
                Button {
                    commit(.fn, notify: true)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to Fn")
            }

            Button {
                capturing ? finishCapture() : beginCapture()
            } label: {
                Text(capturing ? "Press a key…" : hotkey.displayName)
                    .frame(minWidth: 96)
            }
        }
        .onDisappear {
            if capturing { finishCapture() }
        }
    }

    private func beginCapture() {
        capturing = true
        hint = "Esc to cancel"
        pendingModifierKeyCode = nil
        NotificationCenter.default.post(
            name: .hotkeyCaptureStateChanged, object: nil, userInfo: ["capturing": true])

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil // swallow while capturing
        }
    }

    private func handle(_ event: NSEvent) {
        let keyCode = Int64(event.keyCode)

        if event.type == .flagsChanged {
            guard let flag = KeyNames.modifierFlag(for: keyCode) else { return }
            if event.modifierFlags.contains(flag) {
                // Modifier pressed: candidate for a lone-modifier hotkey.
                pendingModifierKeyCode = keyCode
            } else if pendingModifierKeyCode == keyCode {
                // Released without any other key in between → lone modifier.
                commit(keyCode == 63 ? .fn : .modifier(keyCode: keyCode))
            }
            return
        }

        // keyDown
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        pendingModifierKeyCode = nil

        if keyCode == 53 && mods.isEmpty {
            finishCapture()
            return
        }
        // Fn remap 生效时，物理 Fn 到达此处是 F18。
        if keyCode == 79 && mods.isEmpty
            && UserDefaults.standard.bool(forKey: HotkeyMonitor.remapDefaultsKey) {
            commit(.fn)
            return
        }
        if mods.isEmpty && !RecordingHotkey.isAllowedBareKey(keyCode) {
            hint = "Add a modifier (bare keys: F1–F20 only)"
            return
        }
        commit(.key(keyCode: keyCode, modifiers: mods.rawValue))
    }

    private func commit(_ newHotkey: RecordingHotkey, notify: Bool = false) {
        hotkey = newHotkey
        newHotkey.save()
        if capturing {
            finishCapture()
        } else if notify {
            // Reset 按钮不经过捕获态，单独通知 monitor 重载快捷键。
            NotificationCenter.default.post(
                name: .hotkeyCaptureStateChanged, object: nil, userInfo: ["capturing": false])
        }
    }

    private func finishCapture() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        capturing = false
        hint = nil
        pendingModifierKeyCode = nil
        NotificationCenter.default.post(
            name: .hotkeyCaptureStateChanged, object: nil, userInfo: ["capturing": false])
    }
}

// MARK: - Provider (selection + credentials + connection test)

struct ProviderSettingsPane: View {
    @AppStorage(RealtimeProvider.selectionKey) private var providerRaw = RealtimeProvider.dashscope.rawValue
    @State private var tester = ProviderConnectionTester()
    @State private var revealKey = false

    private var provider: RealtimeProvider {
        RealtimeProvider(rawValue: providerRaw) ?? .dashscope
    }

    var body: some View {
        Form {
            Section("Service Provider") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(RealtimeProvider.allCases, id: \.rawValue) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Credentials") {
                HStack(spacing: 8) {
                    Text("API Key")
                        .frame(width: 70, alignment: .leading)
                    Group {
                        if revealKey {
                            TextField("API Key", text: apiKeyBinding, prompt: Text("Enter your API Key"))
                        } else {
                            SecureField("API Key", text: apiKeyBinding, prompt: Text("Enter your API Key"))
                        }
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    Button {
                        revealKey.toggle()
                    } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help("Show/Hide API Key")
                }

                HStack(spacing: 8) {
                    Text("Model")
                        .frame(width: 70, alignment: .leading)
                    TextField("Model", text: modelBinding, prompt: Text(provider.defaultModel))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    Menu {
                        ForEach(provider.models, id: \.self) { m in
                            Button(m) { modelBinding.wrappedValue = m }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Preset models")
                }
            }

            Section {
                HStack {
                    Button {
                        tester.test(provider: provider,
                                    apiKey: apiKeyBinding.wrappedValue,
                                    model: modelBinding.wrappedValue)
                    } label: {
                        if tester.isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(tester.isTesting)
                    Spacer()
                }

                if !tester.statusMessage.isEmpty {
                    Text(tester.statusMessage)
                        .font(.callout)
                        .foregroundStyle(tester.statusColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onChange(of: providerRaw) { _, _ in
            revealKey = false
            tester.reset()
            // 切换即生效：通知状态栏菜单同步勾选。
            NotificationCenter.default.post(name: .realtimeProviderChanged, object: nil)
        }
    }

    /// 每个 provider 独立读写 API Key / 模型，互不覆盖。原始值不做 trim，
    /// 取用时由 `RealtimeProvider.apiKey` / `.model` 负责裁剪。
    private var apiKeyBinding: Binding<String> {
        let key = provider.apiKeyDefaultsKey
        return Binding(
            get: { UserDefaults.standard.string(forKey: key) ?? "" },
            set: { UserDefaults.standard.set($0, forKey: key) }
        )
    }

    private var modelBinding: Binding<String> {
        let key = provider.modelDefaultsKey
        return Binding(
            get: { UserDefaults.standard.string(forKey: key) ?? "" },
            set: { UserDefaults.standard.set($0, forKey: key) }
        )
    }
}

/// 通过 Realtime WebSocket 握手验证 provider / key / model 是否可用。
@Observable
final class ProviderConnectionTester {
    enum Status { case neutral, success, failure, warning }

    var statusMessage = ""
    var status: Status = .neutral
    var isTesting = false

    var statusColor: Color {
        switch status {
        case .neutral: .secondary
        case .success: .green
        case .failure: .red
        case .warning: .orange
        }
    }

    func reset() {
        statusMessage = ""
        status = .neutral
    }

    func test(provider: RealtimeProvider, apiKey: String, model: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            status = .failure
            statusMessage = "API Key is empty."
            return
        }

        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = trimmedModel.isEmpty ? provider.defaultModel : trimmedModel

        isTesting = true
        status = .neutral
        statusMessage = "Testing connection…"

        let encodedModel = modelName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? modelName
        guard let url = URL(string: "\(provider.endpoint)?model=\(encodedModel)") else {
            finish(.failure, "Invalid endpoint URL.")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: request)
        ws.resume()

        ws.receive { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let message):
                    let text: String
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default: text = ""
                    }
                    if text.contains("session.created") {
                        self?.finish(.success, "Connection successful! Model: \(modelName)")
                    } else if text.contains("error") {
                        self?.finish(.failure, "Error: \(text.prefix(200))")
                    } else {
                        self?.finish(.warning, "Unexpected response: \(text.prefix(200))")
                    }
                case .failure(let error):
                    self?.finish(.failure, "Connection failed: \(error.localizedDescription)")
                }
                ws.cancel(with: .normalClosure, reason: nil)
                session.invalidateAndCancel()
            }
        }
    }

    private func finish(_ status: Status, _ message: String) {
        isTesting = false
        self.status = status
        statusMessage = message
    }
}

// MARK: - About

struct AboutSettingsPane: View {
    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (version, build) {
        case let (v?, b?): return "Version \(v) (\(b))"
        case let (v?, nil): return "Version \(v)"
        default: return "Version 1.0"
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("OnlyVoice")
                            .font(.largeTitle.bold())
                        Text(versionText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Tap the recording shortcut (default Fn) to dictate.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("About") {
                Text("A macOS menu bar voice-input tool. It transcribes your speech via Qwen-Omni / Step-Audio Realtime and injects the text at the cursor.")
                    .foregroundStyle(.secondary)
                Link("GitHub", destination: URL(string: "https://github.com/willsho/onlyvoice")!)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
