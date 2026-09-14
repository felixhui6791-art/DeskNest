#!/usr/bin/env swift
import AppKit
import Foundation

// Recreate the icon with native drawing: swift scripts/make-icon.swift
let projectURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let resourcesURL = projectURL.appendingPathComponent("Resources", isDirectory: true)
let temporaryURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("DeskNest-Icon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = temporaryURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func drawCard(_ frame: NSRect, top: NSColor, bottom: NSColor) {
    let path = NSBezierPath(roundedRect: frame, xRadius: 39, yRadius: 39)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0.08, 0.18, 0.12, alpha: 0.23)
    shadow.shadowOffset = NSSize(width: 0, height: -7)
    shadow.shadowBlurRadius = 13
    shadow.set()
    bottom.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: bottom, ending: top)!.draw(in: path, angle: 90)
    color(1, 1, 1, alpha: 0.27).setStroke()
    path.lineWidth = 1.5
    path.stroke()
}

func pngData(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
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
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "DeskNest.Icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法创建图标画布。"])
    }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.setAllowsAntialiasing(true)
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let background = NSBezierPath(
        roundedRect: NSRect(x: 102, y: 102, width: 820, height: 820),
        xRadius: 185,
        yRadius: 185
    )

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0.03, 0.10, 0.06, alpha: 0.27)
    shadow.shadowOffset = NSSize(width: 0, height: -15)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0.23, 0.36, 0.28).setFill()
    background.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(
        starting: color(0.20, 0.34, 0.27),
        ending: color(0.35, 0.48, 0.38)
    )!.draw(in: background, angle: 90)

    color(1, 1, 1, alpha: 0.15).setStroke()
    background.lineWidth = 2
    background.stroke()

    // Unequal rows evoke flexible desktop sections, with generous small-size gaps.
    drawCard(
        NSRect(x: 230, y: 536, width: 270, height: 258),
        top: color(0.98, 0.98, 0.92),
        bottom: color(0.93, 0.94, 0.86)
    )
    drawCard(
        NSRect(x: 538, y: 576, width: 256, height: 218),
        top: color(0.80, 0.87, 0.73),
        bottom: color(0.71, 0.80, 0.65)
    )
    drawCard(
        NSRect(x: 230, y: 230, width: 270, height: 268),
        top: color(0.79, 0.86, 0.75),
        bottom: color(0.69, 0.79, 0.67)
    )
    drawCard(
        NSRect(x: 538, y: 230, width: 256, height: 308),
        top: color(0.99, 0.96, 0.87),
        bottom: color(0.94, 0.90, 0.78)
    )

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "DeskNest.Icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "无法编码 PNG 图标。"])
    }
    return data
}

do {
    try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    for logicalSize in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 1 ? "" : "@2x"
            let outputURL = iconsetURL.appendingPathComponent("icon_\(logicalSize)x\(logicalSize)\(suffix).png")
            try pngData(size: logicalSize * scale).write(to: outputURL)
        }
    }

    let outputURL = resourcesURL.appendingPathComponent("AppIcon.icns")
    let stagedOutputURL = temporaryURL.appendingPathComponent("AppIcon.icns")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetURL.path, "-o", stagedOutputURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "DeskNest.Icon", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "iconutil 未能生成图标。"])
    }
    try Data(contentsOf: stagedOutputURL).write(to: outputURL, options: .atomic)
    print("已生成图标（含 1024 × 1024）：\(outputURL.path)")
} catch {
    FileHandle.standardError.write(Data("图标生成失败：\(error.localizedDescription)\n".utf8))
    exit(1)
}
