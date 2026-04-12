import Foundation
import Starscream

enum DashScopeRealtimeDefaults {
    static let endpoint = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
    static let model = "qwen3-omni-flash-realtime"
    static let models = [
        "qwen3-omni-flash-realtime",
        "qwen3.5-omni-flash-realtime"
    ]
}

/// WebSocket client for Qwen-Omni-Realtime API (DashScope).
/// Uses Manual mode: send audio frames, commit on stop, receive transcription.
final class QwenRealtimeClient: NSObject, WebSocketDelegate {
    private var socket: WebSocket?
    private var isConnected = false
    private var sessionReady = false
    private var isIntentionalDisconnect = false
    private var pendingTranscript = ""
    /// 保留整轮录音，用于连接抖动后重放，避免整段语音丢失。
    private var currentTurnAudio: [String] = []
    /// 本轮是否已经进入 commit 阶段；重连后若仍为 true，需要重新提交整轮音频。
    private var currentTurnCommitted = false

    var onTranscript: ((String) -> Void)?
    var onFinalTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var hasBufferedAudio: Bool { !currentTurnAudio.isEmpty }

    private var apiKey: String {
        (UserDefaults.standard.string(forKey: "dashscope_api_key") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var model: String {
        let value = (UserDefaults.standard.string(forKey: "dashscope_model") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? DashScopeRealtimeDefaults.model : value
    }

    private var language: String {
        UserDefaults.standard.string(forKey: "selected_language") ?? "zh-CN"
    }

    func connect(preserveCurrentTurn: Bool = false) {
        disconnect(clearCurrentTurn: !preserveCurrentTurn)
        pendingTranscript = ""
        sessionReady = false
        if !preserveCurrentTurn {
            currentTurnAudio.removeAll()
            currentTurnCommitted = false
        }

        guard !apiKey.isEmpty else {
            onError?("API Key not configured. Please set it in Settings.")
            return
        }

        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? model
        let urlString = "\(DashScopeRealtimeDefaults.endpoint)?model=\(encodedModel)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("websocket-client/1.6.4", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        print("[QwenRT] Connecting to \(urlString) apiKeyConfigured=true")
        print("[QwenRT] request headers = \(redactedHeaders(from: request))")

        // compressionHandler: nil 关闭 permessage-deflate，避免服务端因未知扩展拒绝
        let ws = WebSocket(request: request, certPinner: FoundationSecurity(), compressionHandler: nil)
        ws.delegate = self
        self.socket = ws
        isIntentionalDisconnect = false
        ws.connect()
    }

    // MARK: - WebSocketDelegate (Starscream)

    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        if let activeSocket = socket, (client as AnyObject) !== activeSocket {
            print("[QwenRT] ignoring event from stale socket")
            return
        }

        switch event {
        case .connected(let headers):
            print("[QwenRT] WebSocket opened, response headers=\(headers)")
            isConnected = true
            isIntentionalDisconnect = false
            // 不立即发送 session.update；等服务端先发 session.created
        case .disconnected(let reason, let code):
            print("[QwenRT] WebSocket closed code=\(code) reason=\(reason)")
            isConnected = false
            if !isIntentionalDisconnect {
                DispatchQueue.main.async {
                    self.onError?(self.userFacingCloseMessage(code: code, reason: reason))
                }
            }
        case .text(let text):
            handleMessage(text)
        case .binary(let data):
            if let text = String(data: data, encoding: .utf8) { handleMessage(text) }
        case .error(let error):
            let msg = error?.localizedDescription ?? "unknown"
            print("[QwenRT] WebSocket error: \(msg)")
            if !isIntentionalDisconnect {
                DispatchQueue.main.async { self.onError?("WebSocket error: \(msg)") }
            }
            isConnected = false
        case .cancelled:
            isConnected = false
            if !isIntentionalDisconnect {
                DispatchQueue.main.async {
                    self.onError?("WebSocket connection cancelled unexpectedly.")
                }
            }
        case .peerClosed:
            isConnected = false
            if !isIntentionalDisconnect {
                DispatchQueue.main.async {
                    self.onError?("WebSocket peer closed the connection unexpectedly.")
                }
            }
        default:
            break
        }
    }

    func disconnect(clearCurrentTurn: Bool = true) {
        isIntentionalDisconnect = true
        isConnected = false
        sessionReady = false
        if clearCurrentTurn {
            currentTurnAudio.removeAll()
            currentTurnCommitted = false
        }
        socket?.disconnect()
        socket = nil
    }

    /// Send Base64-encoded PCM audio frame.
    /// 当前连接可用时立即发送；同时保存整轮音频，便于重连后重放。
    func sendAudioData(_ base64Audio: String) {
        currentTurnAudio.append(base64Audio)
        if currentTurnAudio.count > 600 {  // ~60s 音频
            currentTurnAudio.removeFirst(currentTurnAudio.count - 600)
        }

        if sessionReady {
            sendAppendEvent(base64Audio)
        }
    }

    /// Commit the audio buffer (on Fn key release).
    func commitAudioBuffer() {
        guard !currentTurnAudio.isEmpty else {
            onError?("No audio captured. Please try again.")
            return
        }

        currentTurnCommitted = true

        if sessionReady {
            sendCommitEvents()
        } else {
            print("[QwenRT] commit deferred: session not ready yet, queued=\(currentTurnAudio.count)")
        }
    }

    private func sendAppendEvent(_ base64Audio: String) {
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]
        sendJSON(event)
    }

    private func sendCommitEvents() {
        sendJSON(["type": "input_audio_buffer.commit"])
        sendJSON(["type": "response.create"])
    }

    private func flushCurrentTurn() {
        if !currentTurnAudio.isEmpty {
            print("[QwenRT] replaying \(currentTurnAudio.count) buffered audio frames")
            for frame in currentTurnAudio { sendAppendEvent(frame) }
        }
        if currentTurnCommitted {
            print("[QwenRT] replaying deferred commit")
            sendCommitEvents()
        }
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
        7. If you hear nothing or only noise, return an empty string. Do NOT output placeholder words like "空"/"empty"/"(无)"/"silence" — return literally nothing.
        """

        let sessionConfig: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text"],
                "instructions": instructions,
                "input_audio_format": "pcm",
                "turn_detection": NSNull()  // manual mode; client commits on Fn release
            ]
        ]
        sendJSON(sessionConfig)
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        let preview = str.count > 200 ? String(str.prefix(200)) + "…" : str
        print("[QwenRT] -> \(preview)")
        socket?.write(string: str)
    }

    private func redactedHeaders(from request: URLRequest) -> [String: String] {
        var headers = request.allHTTPHeaderFields ?? [:]
        if headers["Authorization"] != nil {
            headers["Authorization"] = "Bearer <redacted>"
        }
        return headers
    }

    private func userFacingCloseMessage(code: UInt16, reason: String) -> String {
        if reason.localizedCaseInsensitiveContains("access denied") {
            return "Qwen Realtime access denied. Check that the DashScope API Key has access to model \(model), and that the key region matches \(DashScopeRealtimeDefaults.endpoint)."
        }
        return "Qwen Realtime connection closed (\(code)): \(reason)"
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
                let display = Self.isEmptyPlaceholder(self.pendingTranscript) ? "" : self.pendingTranscript
                DispatchQueue.main.async {
                    self.onTranscript?(display)
                }
            }

        case "response.text.done":
            // Text completion for this response item
            if let text = json["text"] as? String {
                pendingTranscript = text
            }

        case "response.done":
            // Full response complete — extract final text
            let rawFinal = extractFinalText(from: json) ?? pendingTranscript
            let finalText = Self.isEmptyPlaceholder(rawFinal) ? "" : rawFinal
            currentTurnAudio.removeAll()
            currentTurnCommitted = false
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

        case "session.created":
            print("[QwenRT] session.created received, sending session.update")
            sendSessionUpdate()

        case "session.updated":
            print("[QwenRT] session.updated — session ready, flushing queued audio")
            sessionReady = true
            flushCurrentTurn()

        default:
            // input_audio_buffer.committed, response.created, etc.
            break
        }
    }

    private static func isEmptyPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。.,，!！?？()（）[]【】\"'“”‘’"))
        if trimmed.isEmpty { return true }
        let placeholders: Set<String> = [
            "空", "无", "（空）", "(空)", "（无）", "(无)",
            "empty", "silence", "none", "(empty)", "(silence)", "(none)"
        ]
        return placeholders.contains(trimmed.lowercased())
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
