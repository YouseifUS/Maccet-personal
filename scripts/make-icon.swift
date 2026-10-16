import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Provide an .iconset output folder") }
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
func render(_ pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("Cannot create icon context") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 78, y: 78, width: 868, height: 868), xRadius: 200, yRadius: 200)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.04, green: 0.19, blue: 0.24, alpha: 1), ending: NSColor(srgbRed: 0.03, green: 0.68, blue: 0.55, alpha: 1))!
    gradient.draw(in: tile, angle: 55)
    NSColor.white.withAlphaComponent(0.16).setStroke(); tile.lineWidth = 3; tile.stroke()
    let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)!
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 460, weight: .medium).applying(.init(paletteColors: [.white])))!
    symbol.draw(in: NSRect(x: 250, y: 265, width: 524, height: 494))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: folder.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: folder.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
