# OnlyVoice

一个极简的 macOS 语音输入工具。按住 `Fn` 说话，松开即把识别结果直接写入当前光标位置。

由阿里云 **Qwen-Omni Realtime** 提供语音转文字能力。

## 特性

- **一键录音**：按住 `Fn` 录音，松开自动结束并注入文本
- **菜单栏常驻**：无 Dock 图标，只在菜单栏显示波形图标
- **胶囊式悬浮面板**：录音时屏幕上显示实时波形与转写预览
- **直接注入**：识别完成后自动粘贴到当前焦点的输入框，无需手动复制
- **多语言识别**：简体中文、繁体中文、English、日本語、한국어
- **可配置模型**：默认 `qwen3.5-omni-flash-realtime`，可在设置中下拉切换

## 系统要求

- macOS 14 (Sonoma) 或更高版本
- Swift 5.9+
- 阿里云百炼（DashScope）API Key

## 构建

```bash
make build      # 构建并打包 OnlyVoice.app
make run        # 构建并启动
make install    # 构建并安装到 /Applications
make clean      # 清理构建产物
```

## 使用

1. 首次启动时授予**麦克风**权限
2. 在 **系统设置 → 隐私与安全性 → 辅助功能** 中勾选 OnlyVoice（用于监听 Fn 键和注入文本）
3. 点击菜单栏波形图标 → **Qwen-Omni Settings...**，填入 DashScope API Key
4. 在任意输入框中按住 `Fn` 说话，松开即转写并写入

## 项目结构

```
Sources/OnlyVoice/
├── main.swift               # 入口
├── AppDelegate.swift        # 菜单栏、状态管理、录音生命周期
├── AudioEngine.swift        # 麦克风采集与 PCM 编码
├── QwenRealtimeClient.swift # Qwen-Omni Realtime WebSocket 客户端
├── FnKeyMonitor.swift       # Fn 按键监听
├── CapsulePanel.swift       # 胶囊悬浮面板 UI
├── WaveformView.swift       # 实时波形可视化
├── SettingsWindow.swift     # API Key / 模型设置窗口
└── TextInjector.swift       # 向当前焦点输入框注入文本
```

## 许可

MIT
