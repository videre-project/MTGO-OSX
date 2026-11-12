import AppKit

/// Exports standard and Retina artwork with matching Finder layout at build time.
@main
enum DiskImageArtwork {
  private static let size = NSSize(width: 720, height: 692)
  private static let iconSize = 112
  private static let appPosition = NSPoint(x: 224, y: 188)
  private static let applicationsPosition = NSPoint(x: 496, y: 188)

  static func main() throws {
    guard CommandLine.arguments.count == 3,
      let artwork = NSImage(contentsOfFile: CommandLine.arguments[1]),
      artwork.size.width > 0, artwork.size.height > 0 else { exit(2) }

    artwork.size = size
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let images = try [1, 2].map { try render(artwork, scale: $0) }
    guard let tiff = NSBitmapImageRep.representationOfImageReps(in: images, using: .tiff, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try tiff.write(to: output.appendingPathComponent("background.tiff"))

    // Include Finder's title bar so the background fits without clipping.
    let frame = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: size), styleMask: .titled)
    let layout: [String: Any] = [
      "window_rect": [[120, 80], [Int(frame.width), Int(frame.height)]],
      "icon_size": iconSize,
      "text_size": 13,
      "label_pos": "bottom",
      "icon_locations": [
        "MTGO.app": [Int(appPosition.x), Int(appPosition.y)],
        "Applications": [Int(applicationsPosition.x), Int(applicationsPosition.y)],
      ],
      "default_view": "icon-view",
      "show_toolbar": false,
      "show_sidebar": false,
      "show_status_bar": false,
      "show_pathbar": false,
      "show_tab_view": false,
      "include_list_view_settings": false,
    ]
    try JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("layout.json"))
  }

  private static func render(_ artwork: NSImage, scale: Int) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw CocoaError(.fileWriteUnknown) }
    bitmap.size = size
    guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    artwork.draw(in: NSRect(origin: .zero, size: size))
    return bitmap
  }
}
