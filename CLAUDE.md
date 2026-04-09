# OnlyVoice

macOS 菜单栏语音输入工具。按住 `Fn` 录音，松开把 Qwen-Omni Realtime 的转写结果注入当前光标。

## 技术栈
- Swift 5.9+ / macOS 14+，无 Dock 图标
- 阿里云 DashScope Qwen-Omni Realtime（WebSocket）

## 构建
`make build | run | install | clean`

## 源码结构（`Sources/OnlyVoice/`）
- `AppDelegate.swift` — 菜单栏与录音生命周期
- `AudioEngine.swift` — 麦克风采集 / PCM 编码
- `QwenRealtimeClient.swift` — Realtime WS 客户端
- `FnKeyMonitor.swift` — Fn 键监听
- `CapsulePanel.swift` / `WaveformView.swift` — 悬浮面板 UI
- `SettingsWindow.swift` — API Key / 模型设置
- `TextInjector.swift` — 焦点输入框注入

## 权限
麦克风 + 辅助功能（监听 Fn、注入文本）。
