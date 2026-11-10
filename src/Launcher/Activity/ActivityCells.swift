import AppKit
import QuartzCore

final class ActivityGroupCell: NSTableCellView {
  private let status = NSImageView()
  private let spinner = CAShapeLayer()
  private let title = NSTextField(labelWithString: "")
  private let summary = NSTextField(labelWithString: "")
  let elapsed = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    status.wantsLayer = true
    spinner.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
    spinner.path = CGPath(ellipseIn: spinner.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
    spinner.fillColor = nil
    spinner.strokeColor = LauncherTheme.accentColor.cgColor
    spinner.lineWidth = 1.5
    spinner.lineCap = .round
    spinner.strokeEnd = 0.75
    spinner.isHidden = true
    status.layer?.addSublayer(spinner)

    title.font = .systemFont(ofSize: 12, weight: .medium)
    title.textColor = .white.withAlphaComponent(0.80)

    summary.font = .systemFont(ofSize: 11)
    summary.textColor = .white.withAlphaComponent(0.45)
    summary.lineBreakMode = .byTruncatingTail
    summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    elapsed.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    elapsed.textColor = .white.withAlphaComponent(0.45)
    elapsed.setContentHuggingPriority(.required, for: .horizontal)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let stack = NSStackView(views: [status, title, summary, spacer, elapsed])
    stack.spacing = 6
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      status.widthAnchor.constraint(equalToConstant: 12),
      status.heightAnchor.constraint(equalToConstant: 12),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func configure(_ operation: LaunchActivity) {
    let symbol: String?
    let color: NSColor
    switch operation.status {
    case .running:
      symbol = nil
      color = LauncherTheme.accentColor
    case .completed:
      symbol = "checkmark"
      color = .white.withAlphaComponent(0.55)
    case .warning:
      symbol = "exclamationmark.circle"
      color = LauncherTheme.accentColor
    case .failed:
      symbol = "exclamationmark.circle"
      color = .systemRed
    case .cancelled:
      symbol = "minus"
      color = .white.withAlphaComponent(0.55)
    }

    let label = String(describing: operation.status)
    status.image = symbol.flatMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: label)
    }
    status.setAccessibilityLabel(label)
    status.contentTintColor = color

    let running = operation.status == .running
    let animates = running && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    spinner.isHidden = !running
    if !animates {
      spinner.removeAnimation(forKey: "spin")
    } else if spinner.animation(forKey: "spin") == nil {
      // Progress updates reuse the cell without restarting its animation.
      let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
      rotation.fromValue = 0
      rotation.toValue = -2 * Double.pi
      rotation.duration = 1
      rotation.repeatCount = .infinity
      spinner.add(rotation, forKey: "spin")
    }

    title.stringValue = operation.id.title
    summary.stringValue = operation.summary ?? ""
    summary.isHidden = operation.summary == nil
    elapsed.stringValue = operation.elapsed()
  }
}

final class ActivityDetailCell: NSTableCellView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    let label = NSTextField(labelWithString: "")
    label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    label.lineBreakMode = .byTruncatingMiddle
    label.isSelectable = true
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    textField = label

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }
}
