import AppKit
import CoreText
import SwiftUI

enum LauncherTheme {
  static let accentColor = NSColor(srgbRed: 225 / 255, green: 136 / 255, blue: 56 / 255, alpha: 1)
  static let accent = Color(nsColor: accentColor)
  static let background = Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255)
  static let artwork = image(named: "MTGO-Background.jpg")
  static let secondary = Color(red: 39 / 255, green: 39 / 255, blue: 42 / 255)
  static let border = Color(red: 82 / 255, green: 82 / 255, blue: 91 / 255)
  static let gameIcon = image(named: "MTGO.ico")

  static func registerFonts() {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("Fonts/Inter.ttf") else { return }

    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
  }

  static let titleFont = font(26, weight: .semibold)
  static let statusFont = font(17, weight: .medium)
  static let bodyFont = font(13)
  static let controlFont = font(13, weight: .medium)

  private static func image(named name: String) -> NSImage? {
    Bundle.main.resourceURL.flatMap { NSImage(contentsOf: $0.appendingPathComponent(name)) }
  }

  private static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .custom("Inter-Regular", size: size).weight(weight)
  }
}
