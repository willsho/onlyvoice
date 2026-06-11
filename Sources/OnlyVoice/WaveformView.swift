import Cocoa

/// 5-bar waveform visualization driven by real-time audio RMS levels.
final class WaveformView: NSView {
    /// Fill color for the bars. The capsule sets this: an adaptive label color on
    /// Liquid Glass (macOS 26+), white on the dark HUD fallback.
    var barColor: NSColor = .labelColor

    /// Bar weights: center-high, sides-low for natural voice shape
    private let barWeights: [Float] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private let barCount = 5
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 3
    private let minBarHeight: CGFloat = 4
    private let maxBarHeight: CGFloat = 30

    /// Smoothed overall-volume envelope per bar
    private var smoothedLevels: [Float] = [0, 0, 0, 0, 0]
    /// 每条独立的振荡相位 + 速度：5 条共享同一 RMS，靠各自相位的正弦调制
    /// 错落起伏，而不是整齐划一地一起动。
    private var phases: [Float] = [0.0, 1.3, 2.6, 0.7, 3.4]
    private let phaseSpeeds: [Float] = [0.14, 0.19, 0.12, 0.17, 0.155]
    private let wobbleBase: Float = 0.45
    private let wobbleAmp: Float = 0.55
    /// 最终显示电平（含 per-bar 振荡），draw 直接使用。
    private var displayLevels: [Float] = [0, 0, 0, 0, 0]

    private let attackRate: Float = 0.40
    private let releaseRate: Float = 0.15

    private var displayLink: CVDisplayLink?
    private var currentRMS: Float = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupDisplayLink()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupDisplayLink()
    }

    deinit {
        stopDisplayLink()
    }

    func updateRMS(_ rms: Float) {
        currentRMS = rms
    }

    func reset() {
        currentRMS = 0
        smoothedLevels = [0, 0, 0, 0, 0]
        displayLevels = [0, 0, 0, 0, 0]
    }

    // MARK: - Display Link

    private func setupDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let link = displayLink else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let ptr = userInfo else { return kCVReturnSuccess }
            let view = Unmanaged<WaveformView>.fromOpaque(ptr).takeUnretainedValue()
            DispatchQueue.main.async {
                view.tick()
            }
            return kCVReturnSuccess
        }, selfPtr)

        CVDisplayLinkStart(link)
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        displayLink = nil
    }

    private func tick() {
        let rms = currentRMS

        for i in 0..<barCount {
            // 整体音量包络（去 RMS 噪声）：fast attack, slow release。
            let target = rms * barWeights[i]
            if target > smoothedLevels[i] {
                smoothedLevels[i] += (target - smoothedLevels[i]) * attackRate
            } else {
                smoothedLevels[i] += (target - smoothedLevels[i]) * releaseRate
            }

            // 每条独立推进相位（带微随机，避免机械循环），用正弦调制错落起伏。
            phases[i] += phaseSpeeds[i] + Float.random(in: -0.02...0.02)
            let wobble = wobbleBase + wobbleAmp * (0.5 + 0.5 * sinf(phases[i]))
            displayLevels[i] = max(0, min(1, smoothedLevels[i] * wobble))
        }

        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let startX = (bounds.width - totalWidth) / 2
        let centerY = bounds.height / 2

        for i in 0..<barCount {
            // 感知增强：gamma<1 放大中低音量的视觉起伏，让波形动效更明显。
            let level = CGFloat(powf(displayLevels[i], 0.65))
            let barHeight = max(minBarHeight, minBarHeight + (maxBarHeight - minBarHeight) * level)
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let y = centerY - barHeight / 2

            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)

            // Bars adapt to the capsule's content color; opacity tracks level.
            let alpha = 0.6 + 0.4 * level
            barColor.withAlphaComponent(alpha).setFill()
            path.fill()
        }
    }

    override var isFlipped: Bool { false }
}
