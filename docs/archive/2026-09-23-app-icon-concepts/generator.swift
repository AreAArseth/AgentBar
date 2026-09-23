// Renders the two 2026-09-23 app icon concepts at 1024x1024.
// Usage: swift generator.swift <lamps|ask> <out.png>
// `lamps` shipped and lives on as Scripts/appicon.swift; `ask` is kept here.
import AppKit
let S: CGFloat = 1024
let variant = CommandLine.arguments[1], out = CommandLine.arguments[2]
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func rr(_ r: CGRect, _ c: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil) }
func shadow(_ y: CGFloat, _ b: CGFloat, _ a: CGFloat) { ctx.setShadow(offset: CGSize(width: 0, height: y), blur: b, color: CGColor(srgbRed: 0.15, green: 0.12, blue: 0.10, alpha: a)) }
let charcoal = rgb(0x262421)
let brand: [UInt32] = [0xD97757, 0x10A37F, 0x8250DF, 0x4285F4]

// Outer ivory base
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState(); shadow(-6, 18, 0.18)
ctx.addPath(rr(body, 185)); ctx.setFillColor(rgb(0xFBF8F2)); ctx.fillPath(); ctx.restoreGState()
ctx.saveGState(); ctx.addPath(rr(body, 185)); ctx.clip()
let g0 = CGGradient(colorsSpace: srgb, colors: [rgb(0xFFFFFF), rgb(0xF1EBE0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g0, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Inner "screen": soft blend of the four agent hues
let pad: CGFloat = 84
let screen = body.insetBy(dx: pad, dy: pad)
ctx.saveGState(); ctx.addPath(rr(screen, 130)); ctx.clip()
ctx.setFillColor(rgb(0xF4B89A)); ctx.fill(screen)
func blob(_ c: CGPoint, _ r: CGFloat, _ hex: UInt32, _ a: CGFloat) {
    let g = CGGradient(colorsSpace: srgb, colors: [rgb(hex, a), rgb(hex, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
}
blob(CGPoint(x: 200, y: 850), 620, 0xE8845F, 1)      // Claude orange, top-left
blob(CGPoint(x: 880, y: 820), 520, 0xF2C98A, 0.9)    // warm sand, top-right
blob(CGPoint(x: 820, y: 180), 620, 0x9A6FE6, 0.95)   // purple, bottom-right
blob(CGPoint(x: 180, y: 180), 560, 0x5E93F0, 0.85)   // blue, bottom-left
blob(CGPoint(x: 520, y: 420), 360, 0xFFF4EA, 0.55)   // light centre
// top gloss
let gl = CGGradient(colorsSpace: srgb, colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gl, start: CGPoint(x: 512, y: screen.maxY), end: CGPoint(x: 512, y: screen.midY), options: [])


func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2*r, height: 2*r) }
func radial(_ c: CGPoint, _ r: CGFloat, _ cols: [CGColor], _ locs: [CGFloat], focus: CGPoint? = nil) {
    let g = CGGradient(colorsSpace: srgb, colors: cols as CFArray, locations: locs)!
    ctx.drawRadialGradient(g, startCenter: focus ?? c, startRadius: 0, endCenter: c, endRadius: r, options: [.drawsAfterEndLocation])
}
func linear(_ from: CGPoint, _ to: CGPoint, _ cols: [CGColor], _ locs: [CGFloat]) {
    let g = CGGradient(colorsSpace: srgb, colors: cols as CFArray, locations: locs)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
// A glossy charcoal slab: soft drop shadow, vertical sheen, top rim light, bottom inner shade.
func slab(_ r: CGRect, _ radius: CGFloat) {
    let p = rr(r, radius)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -28), blur: 60, color: CGColor(srgbRed: 0.18, green: 0.08, blue: 0.2, alpha: 0.45))
    ctx.addPath(p); ctx.setFillColor(charcoal); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(p); ctx.clip()
    linear(CGPoint(x: 0, y: r.maxY), CGPoint(x: 0, y: r.minY), [rgb(0x44403B), rgb(0x2A2724), rgb(0x171513)], [0, 0.45, 1])
    ctx.restoreGState()
    // rim light
    ctx.saveGState(); ctx.addPath(rr(r.insetBy(dx: 3, dy: 3), radius - 3)); ctx.setLineWidth(5)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    linear(CGPoint(x: 0, y: r.maxY), CGPoint(x: 0, y: r.midY), [rgb(0xFFFFFF, 0.35), rgb(0xFFFFFF, 0)], [0, 1])
    ctx.restoreGState()
}
// A glass lamp set into the slab.
func lamp(_ c: CGPoint, _ r: CGFloat, _ hex: UInt32, lit: Bool) {
    // socket
    ctx.saveGState(); ctx.addEllipse(in: circle(c, r + 12)); ctx.clip()
    linear(CGPoint(x: 0, y: c.y + r), CGPoint(x: 0, y: c.y - r), [rgb(0x0E0D0C), rgb(0x3A3632)], [0, 1])
    ctx.restoreGState()
    ctx.saveGState(); ctx.addEllipse(in: circle(c, r)); ctx.clip()
    if lit {
        radial(c, r, [rgb(0xFFE2C8), rgb(0xF59A70), rgb(hex), rgb(0x9C4127)], [0, 0.25, 0.7, 1], focus: CGPoint(x: c.x - r*0.2, y: c.y + r*0.25))
    } else {
        radial(c, r, [rgb(hex, 0.85), rgb(hex, 0.45), rgb(0x0E0D0C, 0.9)], [0, 0.6, 1], focus: CGPoint(x: c.x - r*0.2, y: c.y + r*0.3))
        ctx.setFillColor(rgb(0x000000, 0.35)); ctx.fill(circle(c, r))
    }
    // specular
    ctx.saveGState(); ctx.addEllipse(in: CGRect(x: c.x - r*0.62, y: c.y + r*0.05, width: r*1.24, height: r*0.85)); ctx.clip()
    linear(CGPoint(x: 0, y: c.y + r*0.9), CGPoint(x: 0, y: c.y + r*0.05), [rgb(0xFFFFFF, lit ? 0.7 : 0.32), rgb(0xFFFFFF, 0)], [0, 1])
    ctx.restoreGState()
    ctx.restoreGState()
}
func bloom(_ c: CGPoint, _ r: CGFloat, _ hex: UInt32, _ a: CGFloat) {
    ctx.saveGState(); ctx.setBlendMode(.screen)
    radial(c, r, [rgb(hex, a), rgb(hex, a * 0.35), rgb(hex, 0)], [0, 0.4, 1]); ctx.restoreGState()
}

switch variant {
case "lamps":
    // The island as an object: a glossy slab with four glass lamps, one burning.
    let slabR = CGRect(x: 512 - 300, y: 512 - 118, width: 600, height: 236)
    slab(slabR, 118)
    let step: CGFloat = 132, r: CGFloat = 46
    var x = slabR.midX - step * 1.5
    for (i, h) in brand.enumerated() {
        let c = CGPoint(x: x, y: slabR.midY)
        if i == 0 { ctx.saveGState(); ctx.addPath(rr(slabR, 118)); ctx.clip(); bloom(c, 105, 0xF08A5E, 0.35); ctx.restoreGState() }
        lamp(c, i == 0 ? r + 6 : r, h, lit: i == 0); x += step
    }
    // glow spilling onto the screen below the slab
    bloom(CGPoint(x: slabR.minX + 102, y: slabR.minY - 20), 220, 0xF6A27E, 0.35)
case "ask":
    // The island opened: an agent asking, and the two answers.
    let card = CGRect(x: screen.minX + 56, y: 300, width: screen.width - 112, height: screen.maxY - 300 - 40)
    slab(card, 110)
    let head = CGPoint(x: card.minX + 118, y: card.maxY - 112)
    ctx.saveGState(); ctx.addPath(rr(card, 110)); ctx.clip(); bloom(head, 110, 0xF08A5E, 0.3); ctx.restoreGState()
    lamp(head, 44, brand[0], lit: true)
    for (i, (w, a)) in [(CGFloat(250), CGFloat(0.92)), (170, 0.4)].enumerated() {
        ctx.addPath(rr(CGRect(x: head.x + 76, y: head.y + 8 - CGFloat(i) * 62, width: w, height: 30), 15)); ctx.setFillColor(rgb(0xFBF8F2, a)); ctx.fillPath()
    }
    // buttons
    let bw = (card.width - 64 * 2 - 36) / 2, by = card.minY + 58, bh: CGFloat = 116
    let allow = CGRect(x: card.minX + 64, y: by, width: bw, height: bh)
    let deny = CGRect(x: allow.maxX + 36, y: by, width: bw, height: bh)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x000000, 0.4))
    ctx.addPath(rr(allow, bh/2)); ctx.setFillColor(rgb(0x10A37F)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(rr(allow, bh/2)); ctx.clip()
    linear(CGPoint(x: 0, y: allow.maxY), CGPoint(x: 0, y: allow.minY), [rgb(0x3FD1A6), rgb(0x10A37F), rgb(0x0B7D61)], [0, 0.5, 1]); ctx.restoreGState()
    ctx.addPath(rr(deny, bh/2)); ctx.setFillColor(rgb(0xFFFFFF, 0.12)); ctx.fillPath()
    // check and cross
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(22)
    let ac = CGPoint(x: allow.midX, y: allow.midY)
    ctx.move(to: CGPoint(x: ac.x - 34, y: ac.y + 2)); ctx.addLine(to: CGPoint(x: ac.x - 8, y: ac.y - 24)); ctx.addLine(to: CGPoint(x: ac.x + 38, y: ac.y + 26))
    ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.strokePath()
    let dc = CGPoint(x: deny.midX, y: deny.midY)
    ctx.move(to: CGPoint(x: dc.x - 24, y: dc.y - 24)); ctx.addLine(to: CGPoint(x: dc.x + 24, y: dc.y + 24))
    ctx.move(to: CGPoint(x: dc.x - 24, y: dc.y + 24)); ctx.addLine(to: CGPoint(x: dc.x + 24, y: dc.y - 24))
    ctx.setStrokeColor(rgb(0xFBF8F2, 0.75)); ctx.strokePath()
default: break
}
ctx.restoreGState()
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
