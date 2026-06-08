import Foundation

extension Notification.Name {
    /// 当前启用的 provider 发生变化（菜单或设置窗口触发），用于刷新 UI 勾选状态。
    static let realtimeProviderChanged = Notification.Name("realtimeProviderChanged")
    /// 口语语言发生变化（菜单或设置窗口触发），用于刷新菜单勾选状态。
    static let spokenLanguageChanged = Notification.Name("spokenLanguageChanged")
}

/// 实时转写服务提供方。两家都是 OpenAI Realtime 协议的克隆，差异仅在
/// 端点 / 模型 / 音频格式 / 转写事件路径这些数据上，由本枚举集中描述。
enum RealtimeProvider: String, CaseIterable {
    case dashscope   // 阿里云 DashScope — Qwen-Omni Realtime
    case stepfun     // 阶跃星辰 StepFun — Step-Audio Realtime

    static let selectionKey = "selected_provider"

    /// 当前启用的 provider（默认 dashscope，保持老用户行为不变）。
    static var current: RealtimeProvider {
        let raw = UserDefaults.standard.string(forKey: selectionKey) ?? ""
        return RealtimeProvider(rawValue: raw) ?? .dashscope
    }

    var displayName: String {
        switch self {
        case .dashscope: return "Qwen-Omni (DashScope)"
        case .stepfun:   return "Step-Audio (StepFun)"
        }
    }

    var endpoint: String {
        switch self {
        case .dashscope: return "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
        case .stepfun:   return "wss://api.stepfun.com/v1/realtime"
        }
    }

    var defaultModel: String {
        switch self {
        case .dashscope: return "qwen3-omni-flash-realtime"
        case .stepfun:   return "stepaudio-2.5-realtime"
        }
    }

    var models: [String] {
        switch self {
        case .dashscope:
            return ["qwen3-omni-flash-realtime", "qwen3.5-omni-flash-realtime"]
        case .stepfun:
            return ["stepaudio-2.5-realtime", "step-audio-2", "step-audio-r1.1"]
        }
    }

    /// `input_audio_buffer.append` 的 PCM 格式标识：DashScope 用 "pcm"，StepFun 用 "pcm16"。
    var inputAudioFormat: String {
        switch self {
        case .dashscope: return "pcm"
        case .stepfun:   return "pcm16"
        }
    }

    /// 各 provider 独立保存 API Key / 模型，互不覆盖。
    var apiKeyDefaultsKey: String {
        switch self {
        case .dashscope: return "dashscope_api_key"
        case .stepfun:   return "stepfun_api_key"
        }
    }

    var modelDefaultsKey: String {
        switch self {
        case .dashscope: return "dashscope_model"
        case .stepfun:   return "stepfun_model"
        }
    }

    var apiKey: String {
        (UserDefaults.standard.string(forKey: apiKeyDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var model: String {
        let value = (UserDefaults.standard.string(forKey: modelDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? defaultModel : value
    }
}
