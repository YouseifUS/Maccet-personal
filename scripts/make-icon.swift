import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Provide an .iconset output folder") }
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("assets/branding/maccet-mark.png")
guard let mark = NSImage(contentsOf: source) else { fatalError("Missing Maccet brand artwork: \(source.path)") }
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func render(_ pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("Cannot create icon context") }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()

    // Native tile and padding keep the generated mark consistent at every Dock size.
    let tile = NSBezierPath(roundedRect: NSRect(x: 78, y: 78, width: 868, height: 868), xRadius: 200, yRadius: 200)
    NSColor.white.setFill(); tile.fill(); tile.addClip()
    mark.draw(in: NSRect(x: 62, y: 92, width: 900, height: 900), from: .zero, operation: .sourceOver, fraction: 1)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
    return png
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: folder.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: folder.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
