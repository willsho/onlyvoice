# OnlyVoice

A minimal voice input utility for macOS. Press `Fn` to talk, and the transcription is written directly at the current cursor. Supports both press-and-hold and tap-to-toggle triggers.

Speech-to-text is powered by Alibaba Cloud's **Qwen-Omni Realtime**.

## Features

- **Dual trigger modes**: hold `Fn` to talk and release to stop (walkie-talkie style), or tap `Fn` once to start and again to stop (hands-free)
- **Suppresses system side-effects**: intercepts `Fn` at the HID layer to avoid macOS's built-in "press 🌐 to switch input source / open emoji picker"
- **Menu bar resident**: no Dock icon, only a waveform icon in the menu bar
- **Capsule floating panel**: shows live waveform and transcription preview while recording
- **Direct injection**: automatically pastes the result into the focused text field — no manual copy
- **Multilingual recognition**: Simplified Chinese, Traditional Chinese, English, Japanese, Korean
- **Configurable model**: defaults to `qwen3-omni-flash-realtime`, switchable in Settings

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.9+
- Alibaba Cloud Bailian (DashScope) API Key

## Build

```bash
make build      # Build and package OnlyVoice.app
make run        # Build and launch
make install    # Build and install to /Applications
make clean      # Clean build artifacts
```

## Usage

1. Grant **Microphone** permission on first launch
2. Enable OnlyVoice in **System Settings → Privacy & Security → Accessibility** (required to listen to the Fn key and inject text)
3. Click the waveform icon in the menu bar → **Qwen-Omni Settings...** and enter your DashScope API Key
4. In any text field:
   - **Hold mode**: press and hold `Fn` to talk, release to transcribe and insert
   - **Tap mode**: quickly tap `Fn` (< 0.4s) to start recording, tap again to stop

## Project Structure

```
Sources/OnlyVoice/
├── main.swift               # Entry point
├── AppDelegate.swift        # Menu bar, state, recording lifecycle
├── AudioEngine.swift        # Microphone capture and PCM encoding
├── QwenRealtimeClient.swift # Qwen-Omni Realtime WebSocket client
├── FnKeyMonitor.swift       # Fn key monitoring
├── CapsulePanel.swift       # Capsule floating panel UI
├── WaveformView.swift       # Live waveform visualization
├── SettingsWindow.swift     # API Key / model settings window
└── TextInjector.swift       # Inject text into the focused field
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
