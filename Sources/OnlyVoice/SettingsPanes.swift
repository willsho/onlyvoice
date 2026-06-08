import AppKit
import Observation
import SwiftUI

// MARK: - General (spoken language)

struct GeneralSettingsPane: View {
    @AppStorage("selected_language") private var language = "zh-CN"

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
                        Text("Hold Fn to record, release to transcribe.")
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
