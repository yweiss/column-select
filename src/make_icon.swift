import Cocoa

func renderIcon(size: Int, path: String) {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()

    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let inset = s * 0.085
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.022), blur: s * 0.04, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor.black.setFill()
    squircle.fill()
    ctx.restoreGState()

    ctx.saveGState()
    squircle.addClip()

    let bgGradient = NSGradient(
        starting: NSColor(calibratedRed: 0.19, green: 0.54, blue: 0.98, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.09, green: 0.34, blue: 0.82, alpha: 1.0)
    )!
    bgGradient.draw(in: rect, angle: -90)

    let col1X = rect.minX + rect.width * 0.20
    let col2X = rect.minX + rect.width * 0.80

    NSColor.black.withAlphaComponent(0.10).setFill()
    CGRect(x: rect.minX, y: rect.minY, width: col1X - rect.minX, height: rect.height).fill()
    CGRect(x: col2X, y: rect.minY, width: rect.maxX - col2X, height: rect.height).fill()

    NSColor.white.withAlphaComponent(0.22).setStroke()
    ctx.setLineWidth(max(1.0, s * 0.012))
    ctx.move(to: CGPoint(x: col1X, y: rect.minY))
    ctx.addLine(to: CGPoint(x: col1X, y: rect.maxY))
    ctx.move(to: CGPoint(x: col2X, y: rect.minY))
    ctx.addLine(to: CGPoint(x: col2X, y: rect.maxY))
    ctx.strokePath()

    let barCount = 5
    let padV = rect.height * 0.16
    let usableH = rect.height - padV * 2
    let stepY = usableH / CGFloat(barCount)
    let barH = stepY * 0.56
    let barX = col1X + (col2X - col1X) * 0.14
    let maxBarW = (col2X - col1X) * 0.72
    let widths: [CGFloat] = [0.68, 0.96, 0.76, 0.88, 0.60]

    for i in 0..<barCount {
        let isSelected = (i >= 1 && i <= 3)
        let y = rect.maxY - padV - CGFloat(i + 1) * stepY + (stepY - barH) * 0.5
        let w = maxBarW * widths[i]
        let barRect = CGRect(x: barX, y: y, width: w, height: barH)
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: barH * 0.36, yRadius: barH * 0.36)

        if isSelected {
            NSColor.white.setFill()
        } else {
            NSColor.white.withAlphaComponent(0.26).setFill()
        }
        barPath.fill()
    }

    ctx.restoreGState()
    img.unlockFocus()

    if let tiff = img.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for (px, name) in sizes {
    renderIcon(size: px, path: "\(outDir)/\(name)")
}
