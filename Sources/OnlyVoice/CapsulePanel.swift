import Cocoa

/// Elegant capsule-shaped floating panel for recording visualization.
/// Shows waveform animation + real-time transcript text.
final class CapsulePanel {
    private var panel: NSPanel?
    private var waveformView: WaveformView?
    private var textLabel: NSTextField?
    private var glassView: NSView?
    private var shadowView: NSView?

    private let shadowInset: CGFloat = 24

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
        let windowWidth = initialWidth + shadowInset * 2
        let windowHeight = capsuleHeight + shadowInset * 2
        let frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovable = false
        // Hide traffic lights
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true

        // Transparent root content view — hosts the shadow layer
        let root = NSView(frame: frame)
        root.wantsLayer = true
        p.contentView = root

        // Shadow host: draws a capsule-shaped drop shadow matching the visual effect view
        let shadowHost = NSView()
        shadowHost.wantsLayer = true
        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        let shLayer = shadowHost.layer!
        shLayer.shadowColor = NSColor.black.cgColor
        shLayer.shadowOpacity = 0.28
        shLayer.shadowRadius = 18
        shLayer.shadowOffset = CGSize(width: 0, height: -6)
        shLayer.masksToBounds = false
        root.addSubview(shadowHost)
        self.shadowView = shadowHost

        // Background: Liquid Glass on macOS 26+, visual-effect blur fallback otherwise.
        // `contentHost` is where the waveform + label live; on Liquid Glass it is the
        // glass view's `contentView`, on the fallback it's the visual-effect view itself.
        let (background, contentHost, contentColor) = Self.makeGlassBackground(cornerRadius: cornerRadius)
        background.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.addSubview(background)
        self.glassView = background

        // Waveform view
        let waveform = WaveformView(frame: NSRect(x: 0, y: 0, width: waveformSize.width, height: waveformSize.height))
        waveform.barColor = contentColor
        waveform.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(waveform)
        self.waveformView = waveform

        // Text label
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        label.textColor = contentColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(label)
        self.textLabel = label

        // Constraints
        let wc = shadowHost.widthAnchor.constraint(equalToConstant: initialWidth)
        self.widthConstraint = wc

        NSLayoutConstraint.activate([
            shadowHost.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            shadowHost.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            shadowHost.heightAnchor.constraint(equalToConstant: capsuleHeight),
            wc,

            background.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            background.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            background.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),

            waveform.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: horizontalPadding),
            waveform.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: waveformSize.width),
            waveform.heightAnchor.constraint(equalToConstant: waveformSize.height),

            label.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: elementSpacing),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentHost.trailingAnchor, constant: -horizontalPadding),
            label.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
        ])

        // Position at bottom center of main screen
        positionPanel(p, width: initialWidth)

        self.panel = p

        // Initial shadow path
        p.layoutIfNeeded()
        updateShadowPath()

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
            self?.glassView = nil
            self?.shadowView = nil
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
        }, completionHandler: { [weak self] in
            self?.updateShadowPath()
        })
    }

    private func updateShadowPath() {
        guard let sv = shadowView else { return }
        let b = sv.bounds
        sv.layer?.shadowPath = CGPath(
            roundedRect: b,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
    }

    // MARK: - Private

    /// Builds the capsule background. On macOS 26+ this is a true Liquid Glass
    /// view (`NSGlassEffectView`); older systems fall back to a HUD blur.
    /// Returns the background view plus the view that should host the content.
    private static func makeGlassBackground(cornerRadius: CGFloat) -> (background: NSView, contentHost: NSView, contentColor: NSColor) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            let host = NSView()
            glass.contentView = host
            // Liquid Glass is adaptive (light/dark) — use a semantic color so the
            // waveform and text stay legible over any background.
            return (glass, host, .labelColor)
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            // HUD material is always dark — keep the content white.
            return (effect, effect, .white)
        }
    }

    private func positionPanel(_ panel: NSPanel, width: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowWidth = width + shadowInset * 2
        let windowHeight = capsuleHeight + shadowInset * 2
        let x = screenFrame.midX - windowWidth / 2
        let y = screenFrame.origin.y + 60 - shadowInset  // 60px from bottom (capsule baseline)
        panel.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true)
    }
}
