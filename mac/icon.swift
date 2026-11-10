// Draws the Voxa app icon (indigo-to-magenta circle, white voice waveform) into an .iconset: swift icon.swift <dir>
import AppKit

let heights: [CGFloat] = [0.30, 0.55, 0.85, 0.62, 1.0, 0.58, 0.32]  // a voice, not a symmetric equalizer

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)

    let circle = CGRect(x: 100, y: 112, width: 824, height: 824)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40, color: color(0x000000, 0.35))
    ctx.setFillColor(color(0x4F46E5))
    ctx.fillEllipse(in: circle)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: circle)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x4F46E5), color(0x7C3AED), color(0xDB2777)] as CFArray,
                              locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 900), end: CGPoint(x: 880, y: 150), options: [])
    // Soft light from the top so the circle doesn't look flat.
    let shine = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(shine, startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 900), endRadius: 520, options: [])
    ctx.restoreGState()

    let bar: CGFloat = 60, gap: CGFloat = 38, maxH: CGFloat = 450
    var x = 512 - (CGFloat(heights.count) * bar + CGFloat(heights.count - 1) * gap) / 2
    ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 12, color: color(0x1E1B4B, 0.30))
    ctx.setFillColor(color(0xFFFFFF))
    for h in heights {
        let height = max(bar, maxH * h)
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 524 - height / 2, width: bar, height: height),
                           cornerWidth: bar / 2, cornerHeight: bar / 2, transform: nil))
        ctx.fillPath()
        x += bar + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                   (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    try render(px).write(to: dir.appendingPathComponent("icon_\(name).png"))
}
