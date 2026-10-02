import AppKit

func generateAppIcon() {
    let size = 1024
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let context = NSGraphicsContext.current?.cgContext else { return }

    // 1. Background Squircle
    let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squirclePath = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

    // Dark slate gradient
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1.0).cgColor,
        NSColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1.0).cgColor
    ] as CFArray
    let locations: [CGFloat] = [0.0, 1.0]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
        context.saveGState()
        squirclePath.addClip()
        context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        context.restoreGState()
    }

    // Border highlight
    NSColor(white: 1.0, alpha: 0.12).setStroke()
    squirclePath.lineWidth = 4
    squirclePath.stroke()

    // 2. Glowing Accent Background Ring
    context.saveGState()
    let glowCenter = CGPoint(x: 512, y: 512)
    let glowColors = [
        NSColor(red: 0.20, green: 0.50, blue: 1.0, alpha: 0.35).cgColor,
        NSColor(red: 0.40, green: 0.20, blue: 0.9, alpha: 0.0).cgColor
    ] as CFArray
    if let radial = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        context.drawRadialGradient(radial, startCenter: glowCenter, startRadius: 50, endCenter: glowCenter, endRadius: 360, options: [])
    }
    context.restoreGState()

    // 3. Audio Waveform Bars (Representing Meeting Capture)
    let barHeights: [CGFloat] = [70, 130, 200, 310, 420, 310, 200, 130, 70]
    let barWidth: CGFloat = 26
    let spacing: CGFloat = 46
    let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * (spacing - barWidth)
    let startX = 512 - totalWidth / 2

    for (index, height) in barHeights.enumerated() {
        let x = startX + CGFloat(index) * spacing
        let y = 512 - height / 2
        let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)

        // Gradient for bars (cyan to electric purple)
        let barColors = [
            NSColor(red: 0.25, green: 0.75, blue: 1.0, alpha: 0.95).cgColor,
            NSColor(red: 0.55, green: 0.35, blue: 0.95, alpha: 0.95).cgColor
        ] as CFArray
        if let barGrad = CGGradient(colorsSpace: colorSpace, colors: barColors, locations: [0.0, 1.0]) {
            context.saveGState()
            barPath.addClip()
            context.drawLinearGradient(barGrad, start: CGPoint(x: x, y: y + height), end: CGPoint(x: x, y: y), options: [])
            context.restoreGState()
        }
    }

    // 4. Center Copilot Spark / Shield Motif
    let sparkPath = NSBezierPath()
    sparkPath.move(to: NSPoint(x: 512, y: 640))
    sparkPath.curve(to: NSPoint(x: 542, y: 512), controlPoint1: NSPoint(x: 512, y: 560), controlPoint2: NSPoint(x: 526, y: 526))
    sparkPath.curve(to: NSPoint(x: 670, y: 512), controlPoint1: NSPoint(x: 558, y: 512), controlPoint2: NSPoint(x: 620, y: 512))
    sparkPath.curve(to: NSPoint(x: 542, y: 512), controlPoint1: NSPoint(x: 620, y: 512), controlPoint2: NSPoint(x: 558, y: 512))
    sparkPath.curve(to: NSPoint(x: 512, y: 384), controlPoint1: NSPoint(x: 526, y: 498), controlPoint2: NSPoint(x: 512, y: 464))
    sparkPath.curve(to: NSPoint(x: 482, y: 512), controlPoint1: NSPoint(x: 512, y: 464), controlPoint2: NSPoint(x: 498, y: 498))
    sparkPath.curve(to: NSPoint(x: 354, y: 512), controlPoint1: NSPoint(x: 466, y: 512), controlPoint2: NSPoint(x: 404, y: 512))
    sparkPath.curve(to: NSPoint(x: 482, y: 512), controlPoint1: NSPoint(x: 404, y: 512), controlPoint2: NSPoint(x: 466, y: 512))
    sparkPath.curve(to: NSPoint(x: 512, y: 640), controlPoint1: NSPoint(x: 498, y: 526), controlPoint2: NSPoint(x: 512, y: 560))
    sparkPath.close()

    NSColor.white.withAlphaComponent(0.9).setFill()
    sparkPath.fill()

    image.unlockFocus()

    // Save 1024x1024 master png
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        return
    }

    let fileManager = FileManager.default
    let iconsetURL = URL(fileURLWithPath: "/tmp/AppIcon.iconset")
    try? fileManager.removeItem(at: iconsetURL)
    try? fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

    let masterURL = URL(fileURLWithPath: "/tmp/master_1024.png")
    try? pngData.write(to: masterURL)

    // Generate iconset sizes
    let sizes: [(Int, Int, String)] = [
        (16, 1, "icon_16x16.png"),
        (16, 2, "icon_16x16@2x.png"),
        (32, 1, "icon_32x32.png"),
        (32, 2, "icon_32x32@2x.png"),
        (128, 1, "icon_128x128.png"),
        (128, 2, "icon_128x128@2x.png"),
        (256, 1, "icon_256x256.png"),
        (256, 2, "icon_256x256@2x.png"),
        (512, 1, "icon_512x512.png"),
        (512, 2, "icon_512x512@2x.png")
    ]

    for (pt, scale, name) in sizes {
        let px = pt * scale
        let targetSize = NSSize(width: px, height: px)
        let resizedImage = NSImage(size: targetSize)
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        resizedImage.unlockFocus()

        if let rep = resizedImage.tiffRepresentation,
           let repBitmap = NSBitmapImageRep(data: rep),
           let resizedPng = repBitmap.representation(using: .png, properties: [:]) {
            let outURL = iconsetURL.appendingPathComponent(name)
            try? resizedPng.write(to: outURL)
        }
    }

    print("Iconset generated at /tmp/AppIcon.iconset")
}

generateAppIcon()
