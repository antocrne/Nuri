#!/usr/bin/env swift
// Draws Nuri's icon: the n of the name in the system's serif, and the i's dot beside it. Flat.
// Usage: swift scripts/make-icon.swift Nuri/Assets.xcassets/AppIcon.appiconset
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let letter: CGPath = {
    let descriptor = NSFont.systemFont(ofSize: 200, weight: .medium).fontDescriptor.withDesign(.serif)!
    let font = NSFont(descriptor: descriptor, size: 200)! as CTFont
    var character = UniChar(UnicodeScalar("n").value)
    var glyph = CGGlyph()
    CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
    return CTFontCreatePathForGlyph(font, glyph, nil)!
}()

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // The macOS icon grid: a rounded square inset in its canvas.
    let inset = s * 0.098
    let box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    color(0xF7EDE1).setFill()
    box.fill()
    // The letter sits a little left and low of the middle: with the dot, the whole is centered.
    let bounds = letter.boundingBox
    let scale = box.width * 0.56 / bounds.width
    let x = box.midX - bounds.width * scale / 2 - box.width * 0.03
    let y = box.midY - bounds.height * scale / 2 - box.width * 0.035
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.translateBy(x: x - bounds.minX * scale, y: y - bounds.minY * scale)
    context.scaleBy(x: scale, y: scale)
    context.addPath(letter)
    context.setFillColor(color(0x43362C).cgColor)
    context.fillPath()
    context.restoreGState()
    // Larger when small: the dot is what must survive in the Dock's corner and the tab switcher.
    let radius = box.width * (px <= 64 ? 0.105 : 0.09)
    let center = CGPoint(x: x + bounds.width * scale + box.width * 0.015, y: y + bounds.height * scale + box.width * 0.06)
    color(0xE9A488).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = "icon_\(points)@\(scale)x.png"
        try! render(points * scale).write(to: folder.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted]).write(to: folder.appendingPathComponent("Contents.json"))
