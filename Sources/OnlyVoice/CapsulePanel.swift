import Cocoa

/// Elegant capsule-shaped floating panel for recording visualization.
/// Shows waveform animation + real-time transcript text.
final class CapsulePanel {
    private var panel: NSPanel?
    private var waveformView: WaveformView?
    private var textLabel: NSTextField?
    private var containerView: NSVisualEffectView?

    private let capsuleHeight: CGFloat = 56
    private let cornerRadius: CGFloat = 28
    private let waveformSize = NSSize(width: 44, height: 32)
    private let minTextWidth: CGFloat = 160
    private let maxTextWidth: CGFloat = 560
    private let horizontalPadding: CGFloat = 20
    private let elementSpacing: CGFloat = 12

    private var widthConstraint: NSLayoutConstraint?
    private var currentText: String = ""

    func show() {
        if panel != nil { return }

        // Create non-activating panel
        let initialWidth = horizontalPadding + waveformSize.width + elementSpacing + minTextWidth + horizontalPadding
        let frame = NSRect(x: 0, y: 0, width: initialWidth, height: capsuleHeight)

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovable = false
        // Hide traffic lights
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true

        // Visual effect background
        let effectView = NSVisualEffectView(frame: frame)
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        p.contentView = effectView
        self.containerView = effectView

        // Waveform view
        let waveform = WaveformView(frame: NSRect(x: 0, y: 0, width: waveformSize.width, height: waveformSize.height))
        waveform.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(waveform)
        self.waveformView = waveform

        // Text label
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(label)
        self.textLabel = label

        // Constraints
        let wc = effectView.widthAnchor.constraint(equalToConstant: initialWidth)
        self.widthConstraint = wc

        NSLayoutConstraint.activate([
            effectView.heightAnchor.constraint(equalToConstant: capsuleHeight),
            wc,

            waveform.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: horizontalPadding),
            waveform.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: waveformSize.width),
            waveform.heightAnchor.constraint(equalToConstant: waveformSize.height),

            label.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: elementSpacing),
            label.trailingAnchor.constraint(lessThanOrEqualTo: effectView.trailingAnchor, constant: -horizontalPadding),
            label.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
        ])

        // Position at bottom center of main screen
        positionPanel(p, width: initialWidth)

        self.panel = p

        // Entrance animation: spring scale
        p.alphaValue = 0
        let targetFrame = p.frame
        let smallFrame = NSRect(
            x: targetFrame.midX - targetFrame.width * 0.4,
            y: targetFrame.midY - targetFrame.height * 0.4,
            width: targetFrame.width * 0.8,
            height: targetFrame.height * 0.8
        )
        p.setFrame(smallFrame, display: false)
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            p.animator().setFrame(targetFrame, display: true)
            p.animator().alphaValue = 1.0
        })
    }

    func hide(completion: (() -> Void)? = nil) {
        guard let p = panel else {
            completion?()
            return
        }

        // Exit animation: scale down + fade
        let currentFrame = p.frame
        let smallFrame = NSRect(
            x: currentFrame.midX - currentFrame.width * 0.4,
            y: currentFrame.midY - currentFrame.height * 0.4,
            width: currentFrame.width * 0.8,
            height: currentFrame.height * 0.8
        )

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            p.animator().setFrame(smallFrame, display: true)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            p.orderOut(nil)
            self?.waveformView?.reset()
            self?.waveformView = nil
            self?.textLabel = nil
            self?.containerView = nil
            self?.panel = nil
            self?.currentText = ""
            self?.widthConstraint = nil
            completion?()
        })
    }

    func updateRMS(_ rms: Float) {
        waveformView?.updateRMS(rms)
    }

    func updateTranscript(_ text: String) {
        guard let label = textLabel else { return }
        currentText = text
        label.stringValue = text

        // Calculate needed width
        let textSize = (text as NSString).size(withAttributes: [.font: label.font!])
        let textWidth = min(maxTextWidth, max(minTextWidth, textSize.width + 20))
        let totalWidth = horizontalPadding + waveformSize.width + elementSpacing + textWidth + horizontalPadding

        // Animate width change
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            self.widthConstraint?.animator().constant = totalWidth
            if let p = self.panel {
                self.positionPanel(p, width: totalWidth)
            }
        })
    }

    // MARK: - Private

    private func positionPanel(_ panel: NSPanel, width: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - width / 2
        let y = screenFrame.origin.y + 60  // 60px from bottom
        panel.setFrame(NSRect(x: x, y: y, width: width, height: capsuleHeight), display: true)
    }
}
