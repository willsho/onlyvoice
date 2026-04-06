import Cocoa

/// 5-bar waveform visualization driven by real-time audio RMS levels.
final class WaveformView: NSView {
    /// Bar weights: center-high, sides-low for natural voice shape
    private let barWeights: [Float] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private let barCount = 5
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 3
    private let minBarHeight: CGFloat = 4
    private let maxBarHeight: CGFloat = 28

    /// Smoothed envelope per bar
    private var smoothedLevels: [Float] = [0, 0, 0, 0, 0]
    /// Per-bar random jitter offsets
    private var jitterOffsets: [Float] = [0, 0, 0, 0, 0]

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
            let target = rms * barWeights[i]
            // Jitter: ±4% random offset
            let jitter = Float.random(in: -0.04...0.04)
            jitterOffsets[i] = jitter

            let jitteredTarget = max(0, min(1, target + jitter * target))

            // Envelope follower: fast attack, slow release
            if jitteredTarget > smoothedLevels[i] {
                smoothedLevels[i] += (jitteredTarget - smoothedLevels[i]) * attackRate
            } else {
                smoothedLevels[i] += (jitteredTarget - smoothedLevels[i]) * releaseRate
            }
        }

        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let startX = (bounds.width - totalWidth) / 2
        let centerY = bounds.height / 2

        for i in 0..<barCount {
            let level = CGFloat(smoothedLevels[i])
            let barHeight = max(minBarHeight, minBarHeight + (maxBarHeight - minBarHeight) * level)
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let y = centerY - barHeight / 2

            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)

            // White bars with slight opacity variation based on level
            let alpha = 0.6 + 0.4 * level
            ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            path.fill()
        }
    }

    override var isFlipped: Bool { false }
}
