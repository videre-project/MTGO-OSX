import SwiftUI

/// Related preferences shown in the native settings toolbar panes.
struct LauncherSettingsView: View {
  static let size = CGSize(width: 560, height: 460)

  enum Pane: String, CaseIterable {
    case appearance, behavior, runtime

    var title: String { rawValue.capitalized }
    var symbol: String {
      switch self {
      case .appearance: return "paintpalette"
      case .behavior: return "slider.horizontal.3"
      case .runtime: return "cpu"
      }
    }
  }

  let pane: Pane
  @ObservedObject private var session: LauncherSession
  @ObservedObject private var settings: LauncherSettings
  private let restartSession: () -> Void

  init(pane: Pane, session: LauncherSession, restartSession: @escaping () -> Void) {
    self.pane = pane
    self.session = session
    settings = session.settings
    self.restartSession = restartSession
  }

  var body: some View {
    VStack(spacing: 0) {
      Group {
        switch pane {
        case .appearance: AppearanceSettingsView(settings: settings)
        case .behavior: BehaviorSettingsView(settings: settings)
        case .runtime: RuntimeSettingsView(settings: settings)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if session.requiresRestart {
        Divider()
        HStack(spacing: 16) {
          Text("Restart MTGO to apply changes to the game.")
            .font(.caption)
            .foregroundColor(.secondary)
          Spacer()
          Button("Restart MTGO", action: restartSession)
            .disabled(!session.isRunning)
        }
        .padding(16)
      }
    }
    .frame(width: Self.size.width, height: Self.size.height)
  }
}
