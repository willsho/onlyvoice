import Cocoa

let outputSize = 1024
let columns = 42
let rows = 42
let logoChars = Array("ONLYVOICE#*+=/|")
let backgroundChars = Array("voice.only/fn:-= ")

func blend(_ start: NSColor, _ end: NSColor, fraction: CGFloat) -> NSColor {
    start.blended(withFraction: min(max(fraction, 0), 1), of: end) ?? start
}

func capsulePath(in rect: NSRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
}

func waveformPath(size: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let grid = size / CGFloat(columns)
    let barWidth = grid * 4
    let gap = grid * 2.2
    let heights: [CGFloat] = [0.24, 0.48, 0.62, 0.48, 0.24].map { size * $0 }
    let centerOffsets: [CGFloat] = [0.0, -0.055, 0.0, 0.055, 0.0].map { size * $0 }
    let totalWidth = barWidth * CGFloat(heights.count) + gap * CGFloat(heights.count - 1)
    let originX = (size - totalWidth) / 2
    let centerY = size / 2

    for index in heights.indices {
        let height = heights[index]
        let x = originX + CGFloat(index) * (barWidth + gap)
        let y = centerY + centerOffsets[index] - height / 2
        let rect = NSRect(x: x, y: y, width: barWidth, height: height)
        path.appendRoundedRect(rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
    }

    return path
}

func renderMask(size: Int, path: NSBezierPath) -> [[Double]] {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    let bytesPerRow = rep.bytesPerRow
    let data = rep.bitmapData!

    return (0..<height).map { y in
        (0..<width).map { x in
            let offset = y * bytesPerRow + x * 4
            return Double(data[offset]) / 255.0
        }
    }
}

func charAt(_ chars: [Character], row: Int, col: Int) -> String {
    let index = abs(row * 11 + col * 7 + row * col) % chars.count
    return String(chars[index])
}

func savePNG(_ image: NSImage, to url: URL, size: Int) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "OnlyVoiceIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try png.write(to: url)
}

func icnsChunk(type: String, pngData: Data) -> Data {
    var chunk = Data(type.data(using: .macOSRoman) ?? Data())
    var length = UInt32(pngData.count + 8).bigEndian
    withUnsafeBytes(of: &length) { chunk.append(contentsOf: $0) }
    chunk.append(pngData)
    return chunk
}

func writeICNS(from files: [(String, URL)], to url: URL) throws {
    let typeMap: [String: String] = [
        "icon_16x16.png": "icp4",
        "icon_16x16@2x.png": "ic11",
        "icon_32x32.png": "icp5",
        "icon_32x32@2x.png": "ic12",
        "icon_128x128.png": "ic07",
        "icon_128x128@2x.png": "ic13",
        "icon_256x256.png": "ic08",
        "icon_256x256@2x.png": "ic14",
        "icon_512x512.png": "ic09",
        "icon_512x512@2x.png": "ic10",
    ]

    var body = Data()
    for (name, fileURL) in files {
        guard let type = typeMap[name] else { continue }
        let pngData = try Data(contentsOf: fileURL)
        body.append(icnsChunk(type: type, pngData: pngData))
    }

    var output = Data("icns".data(using: .macOSRoman) ?? Data())
    var totalLength = UInt32(body.count + 8).bigEndian
    withUnsafeBytes(of: &totalLength) { output.append(contentsOf: $0) }
    output.append(body)
    try output.write(to: url)
}

func renderIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    let canvas = NSRect(x: 0, y: 0, width: s, height: s)
    let cornerRadius = s * 0.23
    let squircle = NSBezierPath(roundedRect: canvas, xRadius: cornerRadius, yRadius: cornerRadius)

    let waveform = waveformPath(size: s)
    let mask = renderMask(size: size, path: waveform)

    let backgroundTop = NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.90, alpha: 1.0)
    let backgroundBottom = NSColor(calibratedRed: 0.91, green: 0.89, blue: 0.83, alpha: 1.0)
    let accentStart = NSColor(calibratedRed: 0.02, green: 0.33, blue: 0.38, alpha: 1.0)
    let accentEnd = NSColor(calibratedRed: 0.06, green: 0.54, blue: 0.44, alpha: 1.0)
    let outsideCharColor = NSColor(calibratedWhite: 0.33, alpha: 0.045)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }

    NSColor.clear.setFill()
    canvas.fill()

    squircle.addClip()

    let gradient = NSGradient(starting: backgroundTop, ending: backgroundBottom)!
    gradient.draw(in: canvas, angle: -90)

    let highlight = NSBezierPath(ovalIn: NSRect(x: s * 0.18, y: s * 0.66, width: s * 0.5, height: s * 0.24))
    NSColor.white.withAlphaComponent(0.10).setFill()
    highlight.fill()

    let font = NSFont.monospacedSystemFont(ofSize: s * 0.0235, weight: .bold)
    let cellWidth = s / CGFloat(columns)
    let cellHeight = s / CGFloat(rows)

    for row in 0..<rows {
        for col in 0..<columns {
            let x = CGFloat(col) * cellWidth + cellWidth * 0.04
            let y = CGFloat(rows - row - 1) * cellHeight + cellHeight * 0.03
            let sampleX = min(max(Int((CGFloat(col) + 0.5) / CGFloat(columns) * s), 0), size - 1)
            let sampleY = min(max(Int((CGFloat(row) + 0.5) / CGFloat(rows) * s), 0), size - 1)
            let inside = mask[sampleY][sampleX] > 0.45

            let color: NSColor
            let text: String
            if inside {
                let diagonal = (CGFloat(col) / CGFloat(columns - 1)) * 0.7 + (CGFloat(row) / CGFloat(rows - 1)) * 0.3
                color = blend(accentStart, accentEnd, fraction: diagonal).withAlphaComponent(0.99)
                text = charAt(logoChars, row: row, col: col)
            } else {
                color = outsideCharColor
                text = charAt(backgroundChars, row: row, col: col)
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            text.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
        }
    }

    ctx.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.08)
    shadow.shadowBlurRadius = s * 0.026
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.set()
    NSColor.white.withAlphaComponent(0.035).setFill()
    waveform.fill()
    ctx.restoreGState()

    NSColor.white.withAlphaComponent(0.12).setStroke()
    waveform.lineWidth = s * 0.004
    waveform.stroke()

    NSColor(calibratedWhite: 0.78, alpha: 1.0).setStroke()
    squircle.lineWidth = s * 0.004
    squircle.stroke()

    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: NSSize(width: size, height: size))
    image.addRepresentation(rep)
    return image
}

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let icnsPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let iconsetURL = URL(fileURLWithPath: iconsetPath, isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let icon = renderIcon(size: outputSize)
let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in outputs {
    try savePNG(icon, to: iconsetURL.appendingPathComponent(name), size: pixels)
}

if !icnsPath.isEmpty {
    let files = outputs.map { (name, _) in (name, iconsetURL.appendingPathComponent(name)) }
    try writeICNS(from: files, to: URL(fileURLWithPath: icnsPath))
    print("Generated icns at \(icnsPath)")
}

print("Generated iconset at \(iconsetPath)")
