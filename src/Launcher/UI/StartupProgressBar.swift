import SwiftUI

struct StartupProgressBar: View {
  let fraction: Double?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Rectangle().fill(LauncherTheme.secondary)
        if let fraction {
          Rectangle()
            .fill(LauncherTheme.accent)
            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: fraction)
        } else if reduceMotion {
          Rectangle()
            .fill(LauncherTheme.accent.opacity(0.7))
            .frame(width: geometry.size.width * 0.22)
        } else {
          TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let position = timeline.date.timeIntervalSinceReferenceDate
              .truncatingRemainder(dividingBy: 1.8) / 1.8

            Rectangle()
              .fill(LauncherTheme.accent.opacity(0.9))
              .frame(width: geometry.size.width * 0.22)
              .offset(x: (geometry.size.width * 1.22) * position - geometry.size.width * 0.22)
          }
        }
      }
      .clipShape(Rectangle())
    }
    .frame(height: 3)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("MTGO startup progress")
    .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
  }
}
