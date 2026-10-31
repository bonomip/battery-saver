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
    NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.19, blue: 0.29, alpha: 1),
               ending: NSColor(srgbRed: 0.035, green: 0.07, blue: 0.13, alpha: 1))!.draw(in: tile, angle: -90)
    NSColor.white.withAlphaComponent(0.16).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    let halo = NSBezierPath(ovalIn: NSRect(x: 180, y: 180, width: 664, height: 664))
    NSColor(srgbRed: 0.25, green: 0.85, blue: 0.71, alpha: 0.13).setStroke()
    halo.lineWidth = 28
    halo.stroke()

    let battery = NSBezierPath(roundedRect: NSRect(x: 210, y: 350, width: 560, height: 324), xRadius: 64, yRadius: 64)
    NSColor.white.withAlphaComponent(0.94).setStroke()
    battery.lineWidth = 28
    battery.stroke()
    NSColor.white.withAlphaComponent(0.94).setFill()
    NSBezierPath(roundedRect: NSRect(x: 794, y: 452, width: 30, height: 120), xRadius: 13, yRadius: 13).fill()

    let fill = NSBezierPath(roundedRect: NSRect(x: 248, y: 388, width: 484, height: 248), xRadius: 36, yRadius: 36)
    NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.88, blue: 0.63, alpha: 1),
               ending: NSColor(srgbRed: 0.08, green: 0.64, blue: 0.77, alpha: 1))!.draw(in: fill, angle: -35)
    let bolt = NSBezierPath()
    bolt.move(to: NSPoint(x: 542, y: 646))
    bolt.line(to: NSPoint(x: 420, y: 492))
    bolt.line(to: NSPoint(x: 491, y: 492))
    bolt.line(to: NSPoint(x: 460, y: 378))
    bolt.line(to: NSPoint(x: 592, y: 542))
    bolt.line(to: NSPoint(x: 520, y: 542))
    bolt.close()
    NSColor(srgbRed: 0.04, green: 0.16, blue: 0.23, alpha: 0.35).setStroke()
    bolt.lineWidth = 9
    bolt.lineJoinStyle = .round
    bolt.stroke()
    NSColor.white.setFill()
    bolt.fill()
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
