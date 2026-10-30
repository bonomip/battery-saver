#!/usr/bin/env swift
import AppKit
import Foundation

// Regenerate with: swift -module-cache-path .build/module-cache Scripts/generate_icon.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(size: Int, destination: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 198, yRadius: 198)
    NSGradient(starting: NSColor(srgbRed: 0.22, green: 0.72, blue: 0.42, alpha: 1),
               ending: NSColor(srgbRed: 0.05, green: 0.39, blue: 0.26, alpha: 1))!.draw(in: tile, angle: -90)

    NSColor.white.setStroke()
    let battery = NSBezierPath(roundedRect: NSRect(x: 218, y: 310, width: 548, height: 364), xRadius: 62, yRadius: 62)
    battery.lineWidth = 38
    battery.stroke()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 785, y: 422, width: 42, height: 140), xRadius: 15, yRadius: 15).fill()

    let leaf = NSBezierPath()
    leaf.move(to: NSPoint(x: 358, y: 390))
    leaf.curve(to: NSPoint(x: 662, y: 606), controlPoint1: NSPoint(x: 280, y: 573), controlPoint2: NSPoint(x: 504, y: 638))
    leaf.curve(to: NSPoint(x: 358, y: 390), controlPoint1: NSPoint(x: 659, y: 423), controlPoint2: NSPoint(x: 518, y: 341))
    leaf.fill()
    let vein = NSBezierPath()
    vein.move(to: NSPoint(x: 346, y: 374))
    vein.curve(to: NSPoint(x: 590, y: 550), controlPoint1: NSPoint(x: 409, y: 455), controlPoint2: NSPoint(x: 515, y: 478))
    NSColor(srgbRed: 0.09, green: 0.46, blue: 0.29, alpha: 1).setStroke()
    vein.lineWidth = 20
    vein.lineCapStyle = .round
    vein.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
}

for points in [16, 32, 128, 256, 512] {
    for density in [1, 2] {
        let suffix = density == 2 ? "@2x" : ""
        try drawIcon(size: points * density,
                     destination: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    // Some restricted hosts cannot load iconutil's image codecs. ICNS also accepts PNG chunks directly.
    func integer(_ value: Int) -> Data {
        var value = UInt32(value).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    var chunks = Data()
    for (type, name) in [("icp4", "icon_16x16"), ("icp5", "icon_32x32"),
                         ("icp6", "icon_32x32@2x"), ("ic07", "icon_128x128"),
                         ("ic08", "icon_256x256"), ("ic09", "icon_512x512"),
                         ("ic10", "icon_512x512@2x"), ("ic11", "icon_16x16@2x"),
                         ("ic12", "icon_32x32@2x"), ("ic13", "icon_128x128@2x"),
                         ("ic14", "icon_256x256@2x")] {
        let png = try Data(contentsOf: iconset.appendingPathComponent(name + ".png"))
        chunks.append(Data(type.utf8))
        chunks.append(integer(png.count + 8))
        chunks.append(png)
    }
    var icon = Data("icns".utf8)
    icon.append(integer(chunks.count + 8))
    icon.append(chunks)
    try icon.write(to: root.appendingPathComponent("Resources/AppIcon.icns"))
}
