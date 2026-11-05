// The app icon: the menu bar's sine wave on a soft rounded square, drawn in code.
// `ClaudeChimes --render-app-icon <dir.iconset>` writes every size, then:
//   iconutil -c icns <dir.iconset> -o assets/AppIcon.icns

import AppKit

enum AppIcon {
    /// Draws the icon into a square canvas of `side` points, following the macOS icon grid
    /// (an 824-of-1024 rounded square with a soft drop shadow).
    static func draw(side: CGFloat) {
        let s = side / 1024
        let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.shadowBlurRadius = 28 * s
        shadow.set()
        NSColor(calibratedRed: 0.106, green: 0.106, blue: 0.118, alpha: 1).setFill()   // #1B1B1E
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        // A faint top light, so the tile reads as an object rather than a flat square.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(starting: NSColor(white: 1, alpha: 0.07), ending: NSColor(white: 1, alpha: 0))?
            .draw(in: tile, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // The wave: the same curve as assets/menubar.svg (an 18-unit box), scaled into the tile.
        let unit = 824 * s / 18 * 0.78
        let origin = NSPoint(x: tile.midX - 9 * unit, y: tile.midY - 9 * unit)
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: origin.x + x * unit, y: origin.y + (18 - y) * unit) }
        let wave = NSBezierPath()
        wave.move(to: p(2.2, 9))
        wave.curve(to: p(6.8, 9), controlPoint1: p(3.6, 5.1), controlPoint2: p(5.4, 5.1))
        wave.curve(to: p(11.4, 9), controlPoint1: p(8.2, 12.9), controlPoint2: p(10, 12.9))
        wave.curve(to: p(15.8, 9), controlPoint1: p(12.8, 5.1), controlPoint2: p(14.6, 5.1))
        wave.lineWidth = 1.5 * unit
        wave.lineCapStyle = .round
        wave.lineJoinStyle = .round
        NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1).setStroke()       // #F5F5F7
        wave.stroke()
    }

    static func renderIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = NSSize(width: px, height: px)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current?.imageInterpolation = .high
                draw(side: CGFloat(px))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }
}
