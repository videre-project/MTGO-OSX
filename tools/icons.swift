import AppKit

@main
enum AppIcon {
  static func main() throws {
    guard CommandLine.arguments.count == 3,
      let source = NSImage(contentsOfFile: CommandLine.arguments[1]),
      source.size.width > 0, source.size.height > 0 else { exit(2) }
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let iconset = scratch.appendingPathComponent("MTGO.iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    for size in [16, 32, 128, 256, 512] {
      for scale in [1, 2] {
        let pixels = size * scale
        guard let context = CGContext(
          data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
          bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        draw(source)
        NSGraphicsContext.restoreGraphicsState()
        guard let rendered = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
          throw CocoaError(.fileWriteUnknown)
        }
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png.write(to: iconset.appendingPathComponent(name))
      }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", "-o", output.path, iconset.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(1) }
  }

  private static func draw(_ mark: NSImage) {
    let shape = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                xRadius: 192, yRadius: 192)
    shape.addClip()
    NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 20 / 255, alpha: 1).setFill()
    shape.fill()

    let maxWidth: CGFloat = 640
    let maxHeight: CGFloat = 640
    let ratio = min(maxWidth / mark.size.width, maxHeight / mark.size.height)
    let width = mark.size.width * ratio
    let height = mark.size.height * ratio
    mark.draw(in: NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2,
              width: width, height: height),
         from: .zero, operation: .sourceOver, fraction: 1)
  }
}
