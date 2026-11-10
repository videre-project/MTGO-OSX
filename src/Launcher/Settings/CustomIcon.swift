import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Imports an image into app storage without changing the installed app bundle.
enum CustomIcon {
  static func importImage(from source: URL, into directory: URL) throws -> URL {
    guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 1024,
      ] as CFDictionary),
      let context = CGContext(
        data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else {
      throw ApplicationError(message: "Choose a readable image for the app icon.")
    }

    // Fit the whole image into a square; preserve transparency and aspect ratio.
    let scale = 1024 / CGFloat(max(image.width, image.height))
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(
      x: (1024 - size.width) / 2, y: (1024 - size.height) / 2,
      width: size.width, height: size.height
    ))

    let data = NSMutableData()
    guard let square = context.makeImage(),
      let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
      throw ApplicationError(message: "Could not prepare the app icon.")
    }
    CGImageDestinationAddImage(destination, square, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ApplicationError(message: "Could not save the app icon.")
    }

    // Immutable names keep the icon used by an existing Wine session available.
    let bytes = data as Data
    let name = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + ".png"
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: url.path) {
      try bytes.write(to: url, options: .atomic)
    }
    return url
  }
}
