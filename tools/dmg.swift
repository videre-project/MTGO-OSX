import AppKit
import CoreText

/// Draws the disk image artwork and its matching Finder layout at build time.
@main
enum DiskImageArtwork {
  private static let size = NSSize(width: 640, height: 400)
  private static let iconSize = 112
  private static let appPosition = NSPoint(x: 176, y: 224)
  private static let applicationsPosition = NSPoint(x: 464, y: 224)
  private static let background = NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 20 / 255, alpha: 1)
  private static let accent = NSColor(srgbRed: 225 / 255, green: 136 / 255, blue: 56 / 255, alpha: 1)

  static func main() throws {
    guard CommandLine.arguments.count == 4,
      let artwork = NSImage(contentsOfFile: CommandLine.arguments[1]),
      artwork.size.width > 0, artwork.size.height > 0 else { exit(2) }
    let font = URL(fileURLWithPath: CommandLine.arguments[2])
    guard CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let images = try [1, 2].map { try render(artwork, scale: $0) }
    guard let tiff = NSBitmapImageRep.representationOfImageReps(in: images, using: .tiff, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try tiff.write(to: output.appendingPathComponent("background.tiff"))
    let layout: [String: Any] = [
      "window_rect": [[160, 160], [Int(size.width), Int(size.height)]],
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
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    graphics.imageInterpolation = .high
    let bounds = NSRect(origin: .zero, size: size)
    background.setFill()
    bounds.fill()
    let width = size.height * artwork.size.width / artwork.size.height
    artwork.draw(in: NSRect(x: size.width - width, y: 0, width: width, height: size.height),
      from: .zero, operation: .sourceOver, fraction: 0.60)
    NSGradient(colorsAndLocations:
      (background, 0), (background.withAlphaComponent(0.95), 0.36),
      (background.withAlphaComponent(0.15), 1))?.draw(in: bounds, angle: 0)
    NSGradient(colorsAndLocations:
      (background, 0), (background.withAlphaComponent(0.97), 0.36),
      (background.withAlphaComponent(0.10), 1))?.draw(in: bounds, angle: 90)

    text("Install MTGO", x: 40, y: 32, width: 400, height: 38, size: 28, weight: .semibold)
    text("Drag MTGO to Applications to get started.", x: 40, y: 77,
      width: 530, height: 24, size: 13, opacity: 0.72)

    // Include Finder's selection outline and filename row in the panel bounds.
    let iconHalfSize = CGFloat(iconSize) / 2
    let selectionOutset: CGFloat = 7
    let labelGap: CGFloat = 3
    let labelHeight: CGFloat = 16
    let panelPadding: CGFloat = 7
    let panelLeft = appPosition.x - iconHalfSize - selectionOutset - panelPadding
    let panelRight = applicationsPosition.x + iconHalfSize + selectionOutset + panelPadding
    let panelTop = appPosition.y - iconHalfSize - selectionOutset - panelPadding
    let panelBottom = appPosition.y + iconHalfSize + selectionOutset + labelGap + labelHeight + panelPadding
    let panel = NSRect(x: panelLeft, y: size.height - panelBottom, width: panelRight - panelLeft,
      height: panelBottom - panelTop)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: panel, xRadius: 16, yRadius: 16).fill()

    let rim = NSBezierPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), xRadius: 15.5, yRadius: 15.5)
    rim.lineWidth = 1
    NSColor.white.withAlphaComponent(0.16).setStroke()
    rim.stroke()

    let arrow = NSBezierPath()
    let x = (appPosition.x + applicationsPosition.x) / 2
    let y = size.height - appPosition.y
    arrow.move(to: NSPoint(x: x - 32, y: y))
    arrow.line(to: NSPoint(x: x + 32, y: y))
    arrow.move(to: NSPoint(x: x + 20, y: y + 10))
    arrow.line(to: NSPoint(x: x + 32, y: y))
    arrow.line(to: NSPoint(x: x + 20, y: y - 10))
    arrow.lineWidth = 2
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    accent.withAlphaComponent(0.80).setStroke()
    arrow.stroke()

    text("Then open MTGO from Applications.", x: 40, y: 345,
      width: 560, height: 20, size: 12, opacity: 0.50)
    return bitmap
  }

  private static func text(
    _ value: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
    size fontSize: CGFloat, weight: NSFont.Weight = .regular, opacity: CGFloat = 1
  ) {
    let family = NSFont(name: "Inter-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize)
    let font = NSFontManager.shared.convert(family, toHaveTrait: weight == .semibold ? .boldFontMask : [])
    (value as NSString).draw(in: NSRect(x: x, y: size.height - y - height, width: width, height: height),
      withAttributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(opacity)])
  }
}
