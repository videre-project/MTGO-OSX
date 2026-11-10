import SwiftUI

struct LauncherBackground: View {
  var body: some View {
    LauncherTheme.background.overlay {
      if let artwork = LauncherTheme.artwork {
        ZStack {
          GeometryReader { geometry in
            Image(nsImage: artwork)
              .resizable()
              .interpolation(.high)
              .scaledToFill()
              .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
              .opacity(0.65)
          }

          // Fade the artwork into the text area and the activity panel below it.
          LinearGradient(stops: [
            .init(color: LauncherTheme.background, location: 0),
            .init(color: LauncherTheme.background, location: 0.4),
            .init(color: LauncherTheme.background.opacity(0.3), location: 0.65),
            .init(color: .clear, location: 1),
          ], startPoint: .leading, endPoint: .trailing)

          LinearGradient(stops: [
            .init(color: .clear, location: 0.25),
            .init(color: LauncherTheme.background.opacity(0.6), location: 0.6),
            .init(color: LauncherTheme.background, location: 0.82),
          ], startPoint: .top, endPoint: .bottom)
        }
      }
    }
    .clipped()
    .accessibilityHidden(true)
  }
}
