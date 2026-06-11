import AVFoundation
import Foundation
import Speech

/// 本地 on-device 语音识别，用于录音时的低延迟实时预览。
/// 与云端转写并行：本地一出 partial 就把草稿打进光标处，云端 final 到达后再替换。
/// 完全离线（`requiresOnDeviceRecognition = true`），不上传音频。
///
/// SFSpeech 在检测到静默时会对当前段落 endpoint（`isFinal`）并结束该识别任务，
/// 且 finalize 前后可能吐出空/回退的 partial。因此这里按段处理：每段 `isFinal`
/// 后把文本固化进 `committedText` 并立即重启新段，新段 partial 始终拼在已固化
/// 文本之后，空结果直接丢弃。这样停顿处文字被「定稿」而非清空，停顿后仍能继续预览。
final class LocalSpeechRecognizer {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// 已 finalize 的段落前缀，跨停顿累积。
    private var committedText = ""
    private var isStopped = true
    private let lock = NSLock()

    /// 最新的完整识别结果（非增量，非空）。主线程回调。
    var onPartial: ((String) -> Void)?

    /// 启动时请求一次语音识别授权。
    static func requestAuthorization(_ completion: ((Bool) -> Void)? = nil) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion?(status == .authorized) }
        }
    }

    /// 启动一轮识别。返回 false 表示当前语言/设备不支持离线识别，
    /// 调用方应回退到「仅胶囊预览 + 云端粘贴」的旧流程。
    func start(localeID: String) -> Bool {
        stop()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return false }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
              rec.isAvailable, rec.supportsOnDeviceRecognition else { return false }
        lock.lock()
        recognizer = rec
        committedText = ""
        isStopped = false
        lock.unlock()
        startSegment()
        return true
    }

    /// 喂入原始麦克风 buffer（SFSpeech 内部自行重采样）。可在音频线程调用。
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        request?.append(buffer)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        isStopped = true
        let req = request
        let t = task
        request = nil
        task = nil
        recognizer = nil
        committedText = ""
        lock.unlock()
        req?.endAudio()
        t?.cancel()
    }

    // MARK: - Private

    private func startSegment() {
        lock.lock()
        guard !isStopped, let rec = recognizer else { lock.unlock(); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        // 本地预览只是草稿，标点交给云端，保持与云端 prompt 一致的「不主动加标点」。
        req.addsPunctuation = false
        request = req
        lock.unlock()

        let t = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            // 只处理当前段的回调，忽略旧段迟到结果。
            self.lock.lock()
            let isCurrent = (self.request === req)
            let committed = self.committedText
            self.lock.unlock()
            guard isCurrent else { return }

            if let result = result {
                let combined = self.combine(committed, result.bestTranscription.formattedString)
                if !combined.isEmpty {
                    DispatchQueue.main.async { self.onPartial?(combined) }
                }
                // SFSpeech 在 audio-buffer 模式下，停顿不发 isFinal，只有录音结束
                // (endAudio) 或超过约 1 分钟才会 isFinal。这里固化已识别文本并重启
                // 新段，使长录音的预览不中断。partial 由胶囊整句刷新，无副作用。
                if result.isFinal {
                    self.lock.lock()
                    self.committedText = combined
                    self.lock.unlock()
                    self.restartSegment()
                }
            } else if error != nil {
                self.restartSegment()
            }
        }

        lock.lock()
        if request === req { task = t } else { t.cancel() }
        lock.unlock()
    }

    /// 当前段结束（isFinal / error）后，若仍在录音则重启下一段继续识别。
    private func restartSegment() {
        lock.lock()
        let stopped = isStopped
        let oldReq = request
        request = nil
        task = nil
        lock.unlock()
        guard !stopped else { return }
        oldReq?.endAudio()
        startSegment()
    }

    private func combine(_ base: String, _ tail: String) -> String {
        base.isEmpty ? tail : (tail.isEmpty ? base : base + tail)
    }
}
