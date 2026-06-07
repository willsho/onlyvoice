# OnlyVoice

macOS 菜单栏语音输入工具。按住 `Fn` 录音，松开把 Realtime 转写结果注入当前光标。

## 技术栈
- Swift 5.9+ / macOS 14+，无 Dock 图标
- Realtime WebSocket，双 provider 可切换：阿里云 DashScope（Qwen-Omni）/ 阶跃星辰 StepFun（Step-Audio）
- 两家均为 OpenAI Realtime 协议克隆；差异仅端点/模型/音频格式（pcm vs pcm16）/转写事件（`response.text.*` vs `response.audio_transcript.*`）

## 构建
`make build | run | install | clean`

## 源码结构（`Sources/OnlyVoice/`）
- `AppDelegate.swift` — 菜单栏与录音生命周期
- `AudioEngine.swift` — 麦克风采集 / PCM 编码
- `RealtimeClient.swift` — Realtime WS 客户端（provider 无关）
- `RealtimeProvider.swift` — 服务商配置（端点/模型/音频格式/事件路径）+ 当前选中状态
- `FnKeyMonitor.swift` — Fn 键监听
- `CapsulePanel.swift` / `WaveformView.swift` — 悬浮面板 UI
- `SettingsWindow.swift` — 服务商 / API Key / 模型设置
- `TextInjector.swift` — 焦点输入框注入

## 权限
麦克风 + 辅助功能（监听 Fn、注入文本）。
