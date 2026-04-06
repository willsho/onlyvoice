import Foundation

/// WebSocket client for Qwen-Omni-Realtime API (DashScope).
/// Uses Manual mode: send audio frames, commit on stop, receive transcription.
final class QwenRealtimeClient {
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isConnected = false
    private var pendingTranscript = ""

    var onTranscript: ((String) -> Void)?
    var onFinalTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var apiKey: String { UserDefaults.standard.string(forKey: "dashscope_api_key") ?? "" }
    private var model: String { UserDefaults.standard.string(forKey: "dashscope_model") ?? "qwen-omni-turbo-latest" }

    private var language: String {
        UserDefaults.standard.string(forKey: "selected_language") ?? "zh-CN"
    }

    func connect() {
        disconnect()
        pendingTranscript = ""

        guard !apiKey.isEmpty else {
            onError?("API Key not configured. Please set it in Settings.")
            return
        }

        let urlString = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=\(model)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        self.urlSession = session
        let ws = session.webSocketTask(with: request)
        self.webSocket = ws
        ws.resume()

        isConnected = true
        receiveMessages()
        sendSessionUpdate()
    }

    func disconnect() {
        isConnected = false
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    /// Send Base64-encoded PCM audio frame
    func sendAudioData(_ base64Audio: String) {
        guard isConnected else { return }
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]
        sendJSON(event)
    }

    /// Commit the audio buffer (on Fn key release)
    func commitAudioBuffer() {
        guard isConnected else { return }
        let event: [String: Any] = [
            "type": "input_audio_buffer.commit"
        ]
        sendJSON(event)
        // Request a response after committing
        let responseEvent: [String: Any] = [
            "type": "response.create"
        ]
        sendJSON(responseEvent)
    }

    // MARK: - Private

    private func sendSessionUpdate() {
        let langName: String
        switch language {
        case "zh-CN": langName = "Simplified Chinese"
        case "zh-TW": langName = "Traditional Chinese"
        case "en-US": langName = "English"
        case "ja-JP": langName = "Japanese"
        case "ko-KR": langName = "Korean"
        default: langName = "Simplified Chinese"
        }

        let instructions = """
        You are a speech-to-text transcription assistant. Your ONLY job is to output the exact text that was spoken, in \(langName).

        CRITICAL RULES:
        1. Output ONLY the transcribed text. No explanations, no greetings, no commentary.
        2. Fix ONLY obvious speech recognition errors:
           - Chinese homophone errors (e.g. 的/得/地 confusion from speech)
           - English technical terms misrecognized as Chinese (e.g. 配森→Python, 杰森→JSON, 瑞安→Ryan)
           - Clear mishearing of proper nouns or technical jargon
        3. NEVER rewrite, rephrase, polish, summarize, or delete any content that appears correct.
        4. If the input sounds correct, return it EXACTLY as heard.
        5. Preserve the original language mix (Chinese-English code-switching is normal).
        6. NEVER add punctuation that wasn't implied by speech pauses.
        7. If you hear nothing or only noise, return an empty string.
        """

        let sessionConfig: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text"],
                "instructions": instructions,
                "input_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": "whisper-1",
                    "language": language
                ],
                "turn_detection": NSNull() // Manual mode
            ]
        ]
        sendJSON(sessionConfig)
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(str)) { error in
            if let error = error {
                print("[QwenRT] Send error: \(error.localizedDescription)")
            }
        }
    }

    private func receiveMessages() {
        webSocket?.receive { [weak self] result in
            guard let self = self, self.isConnected else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                // Continue receiving
                self.receiveMessages()

            case .failure(let error):
                print("[QwenRT] Receive error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onError?("WebSocket error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "response.text.delta":
            // Streaming text delta
            if let delta = json["delta"] as? String {
                pendingTranscript += delta
                DispatchQueue.main.async {
                    self.onTranscript?(self.pendingTranscript)
                }
            }

        case "response.text.done":
            // Text completion for this response item
            if let text = json["text"] as? String {
                pendingTranscript = text
            }

        case "response.done":
            // Full response complete — extract final text
            let finalText = extractFinalText(from: json) ?? pendingTranscript
            DispatchQueue.main.async {
                self.onFinalTranscript?(finalText)
            }

        case "error":
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                DispatchQueue.main.async {
                    self.onError?(message)
                }
            }

        default:
            // session.created, session.updated, input_audio_buffer.committed, etc.
            break
        }
    }

    private func extractFinalText(from json: [String: Any]) -> String? {
        // response.done contains the full response object
        guard let response = json["response"] as? [String: Any],
              let output = response["output"] as? [[String: Any]] else { return nil }

        for item in output {
            if let content = item["content"] as? [[String: Any]] {
                for part in content {
                    if part["type"] as? String == "text",
                       let text = part["text"] as? String {
                        return text
                    }
                }
            }
        }
        return nil
    }
}
