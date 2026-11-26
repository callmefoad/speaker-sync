// Renders the Speaker Sync app icon as a 1024px PNG.
// Two speakers (wired = orange, Bluetooth = blue) joined by one in-sync wave.
// Usage: swift make_icon.swift out.png
import AppKit

let px = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Apple-style continuous-corner squircle (superellipse).
func squircle(_ r: NSRect, n: Double = 5) -> NSBezierPath {
    let p = NSBezierPath()
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let pt = NSPoint(x: r.midX + CGFloat(x) * r.width / 2, y: r.midY + CGFloat(y) * r.height / 2)
        i == 0 ? p.move(to: pt) : p.line(to: pt)
    }
    p.close()
    return p
}

func circle(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}

func withShadow(_ color: NSColor, blur: CGFloat, dy: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = color
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: dy)
    s.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

let canvas = CGFloat(px)
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(body)

// --- Background -------------------------------------------------------------
withShadow(.black.withAlphaComponent(0.35), blur: 30, dy: -14) { rgb(0x0B1020).setFill(); shape.fill() }

NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(starting: rgb(0x070B16), ending: rgb(0x1C2848))!.draw(in: body, angle: 90)
// soft glow behind the speakers
NSGradient(colors: [rgb(0x4B63D8, 0.45), rgb(0x4B63D8, 0)])!
    .draw(fromCenter: NSPoint(x: 512, y: 560), radius: 0, toCenter: NSPoint(x: 512, y: 560), radius: 430, options: [])
// top sheen
NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: body.minX, y: body.midY + 120, width: body.width, height: body.height / 2 - 120), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// thin inner edge highlight
NSGraphicsContext.saveGraphicsState()
shape.addClip()
rgb(0xFFFFFF, 0.10).setStroke()
shape.lineWidth = 4
shape.stroke()
NSGraphicsContext.restoreGraphicsState()

// --- Speakers ---------------------------------------------------------------
struct Accent { let light: UInt32; let dark: UInt32 }
let orange = Accent(light: 0xFFB547, dark: 0xFF5E1A)
let blue = Accent(light: 0x6CB6FF, dark: 0x1F57F0)

func speaker(centerX: CGFloat, accent: Accent) {
    let cab = NSRect(x: centerX - 128, y: 360, width: 256, height: 400)
    let cabPath = NSBezierPath(roundedRect: cab, xRadius: 62, yRadius: 62)

    withShadow(.black.withAlphaComponent(0.55), blur: 34, dy: -18) { rgb(0xD9DCE2).setFill(); cabPath.fill() }
    NSGradient(starting: rgb(0xB9BEC8), ending: rgb(0xF7F8FA))!.draw(in: cabPath, angle: 90)

    // inner bevel
    NSGraphicsContext.saveGraphicsState()
    cabPath.addClip()
    let inner = NSBezierPath(roundedRect: cab.insetBy(dx: 3, dy: 3), xRadius: 59, yRadius: 59)
    rgb(0xFFFFFF, 0.7).setStroke(); inner.lineWidth = 4; inner.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // woofer
    let w = NSPoint(x: centerX, y: cab.minY + 132)
    withShadow(rgb(accent.dark, 0.55), blur: 18, dy: 0) { rgb(accent.dark).setFill(); circle(w, 96).fill() }
    NSGradient(starting: rgb(accent.dark), ending: rgb(accent.light))!.draw(in: circle(w, 96), angle: 90)
    NSGradient(starting: rgb(0x2C323E), ending: rgb(0x0E1117))!.draw(in: circle(w, 74), angle: 90)
    NSGradient(colors: [rgb(0x3A4150), rgb(0x161A22)])!.draw(in: circle(w, 54), relativeCenterPosition: NSPoint(x: -0.3, y: 0.4))
    NSGradient(starting: rgb(0x5A6272), ending: rgb(0x242934))!.draw(in: circle(w, 24), angle: 90)

    // tweeter
    let t = NSPoint(x: centerX, y: cab.maxY - 88)
    NSGradient(starting: rgb(accent.dark), ending: rgb(accent.light))!.draw(in: circle(t, 38), angle: 90)
    NSGradient(starting: rgb(0x2C323E), ending: rgb(0x0E1117))!.draw(in: circle(t, 26), angle: 90)
    NSGradient(starting: rgb(0x6A7282), ending: rgb(0x2A303C))!.draw(in: circle(t, 10), angle: 90)
}

speaker(centerX: 512 - 152, accent: orange)
speaker(centerX: 512 + 152, accent: blue)

// --- Sync wave --------------------------------------------------------------
let wave = NSBezierPath()
let x0: CGFloat = 230, x1: CGFloat = 794, midY: CGFloat = 238, amp: CGFloat = 36
for i in 0...400 {
    let f = CGFloat(i) / 400
    let x = x0 + (x1 - x0) * f
    let env = sin(f * .pi)                          // taper at both ends
    let y = midY + amp * env * sin(f * .pi * 2 * 2.5)
    i == 0 ? wave.move(to: NSPoint(x: x, y: y)) : wave.line(to: NSPoint(x: x, y: y))
}
wave.lineWidth = 24
wave.lineCapStyle = .round
wave.lineJoinStyle = .round

let stroked = NSBezierPath()
if let cg = wave.cgPath.copy(strokingWithWidth: 24, lineCap: .round, lineJoin: .round, miterLimit: 10) as CGPath? {
    stroked.append(NSBezierPath(cgPath: cg))
}
withShadow(rgb(0x7A8CFF, 0.8), blur: 26, dy: 0) { rgb(0xFFFFFF).setFill(); stroked.fill() }
NSGradient(colors: [rgb(orange.light), rgb(0xFF7AC2), rgb(blue.light)])!.draw(in: stroked, angle: 0)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
