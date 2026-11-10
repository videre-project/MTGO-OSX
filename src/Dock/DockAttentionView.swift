import AppKit

enum DockAttentionMode: String {
  case off, steady, pulsing
}

/// Marks taskbar attention on the existing application icon until MTGO regains focus.
@MainActor
final class DockAttentionView: NSView {
  private var timer: Timer?
  private var pulseStartedAt: TimeInterval?
  private var previousContentView: NSView?
  private let pulseDuration: TimeInterval = 2.4

  init() {
    super.init(frame: NSRect(origin: .zero, size: NSApplication.shared.dockTile.size))
    autoresizingMask = [.width, .height]
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityLabel("MTGO needs attention")
  }

  required init?(coder: NSCoder) { nil }

  deinit { timer?.invalidate() }

  func show(animated: Bool = true) {
    let tile = NSApplication.shared.dockTile
    guard tile.contentView !== self else { return }

    previousContentView = tile.contentView
    tile.contentView = self
    if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      pulseStartedAt = ProcessInfo.processInfo.systemUptime
      let timer = Timer(timeInterval: 1 / 24, repeats: true) { [weak self] _ in
        Task { @MainActor [weak self] in self?.advancePulse() }
      }
      self.timer = timer
      RunLoop.main.add(timer, forMode: .common)
    }
    tile.display()
  }

  func clear() {
    stopPulsing()

    let tile = NSApplication.shared.dockTile
    let original = previousContentView
    previousContentView = nil
    guard tile.contentView === self else { return }

    // Return drawing to AppKit so the normal icon and Dock behavior stay intact.
    tile.contentView = original
    tile.display()
  }

  private func advancePulse() {
    if let started = pulseStartedAt,
      ProcessInfo.processInfo.systemUptime - started >= pulseDuration
        || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      stopPulsing()
    }

    NSApplication.shared.dockTile.display()
  }

  private func stopPulsing() {
    timer?.invalidate()
    timer = nil
    pulseStartedAt = nil
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.setFill()
    bounds.fill(using: .copy)
    NSApplication.shared.applicationIconImage?.draw(in: bounds)

    let size = min(bounds.width, bounds.height)
    let center = NSPoint(x: bounds.minX + bounds.width * 0.82, y: bounds.minY + bounds.height * 0.82)
    let radius = size * 0.12
    let elapsed = pulseStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
    let phase = min(elapsed / pulseDuration, 1)
    let pulse = CGFloat((1 - cos(phase * 4 * .pi)) / 2)

    // Two soft pulses draw attention, then a steady dot needs no redraw timer.
    let haloRadius = radius + size * 0.035 * pulse
    NSColor.systemOrange.withAlphaComponent(0.25 * pulse).setFill()
    NSBezierPath(ovalIn: NSRect(
      x: center.x - haloRadius, y: center.y - haloRadius,
      width: haloRadius * 2, height: haloRadius * 2
    )).fill()

    let dot = NSBezierPath(ovalIn: NSRect(
      x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
    ))
    NSColor(calibratedWhite: 0.08, alpha: 0.95).setStroke()
    dot.lineWidth = size * 0.025
    dot.stroke()
    NSColor.systemOrange.withAlphaComponent(1 - 0.55 * pulse).setFill()
    dot.fill()
  }
}
