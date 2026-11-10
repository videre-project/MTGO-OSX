import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct AppearanceSettingsView: View {
  @ObservedObject var settings: LauncherSettings

  var body: some View {
    Form {
      Section("App icon") {
        HStack(spacing: 20) {
          if let image = settings.iconImage {
            Image(nsImage: image)
              .resizable()
              .interpolation(.high)
              .scaledToFit()
              .frame(width: 80, height: 80)
              .accessibilityLabel("Selected app icon")
          }
          VStack(alignment: .leading, spacing: 10) {
            Text(settings.customIconURL == nil ? "MTGO" : "Custom icon")
              .font(.headline)
            HStack {
              Button("Choose Image…", action: chooseIcon)
              Button("Reset", action: settings.resetIcon)
                .disabled(settings.customIconURL == nil)
            }
          }
        }
        Text("Used by the running app in the Dock and by MTGO windows. Finder keeps the installed app icon.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Section("Startup") {
        Toggle("Animate the transition to MTGO", isOn: $settings.animateTransitions)
        Text("Fades and resizes the launcher into the game window. Follows Reduce Motion in System Settings.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func chooseIcon() {
    let panel = NSOpenPanel()
    panel.title = "Choose an app icon"
    panel.prompt = "Use Icon"
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
      .compactMap { UTType($0) }
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      try settings.selectIcon(url)
    } catch {
      let alert = NSAlert()
      alert.messageText = "Could not change the app icon"
      alert.informativeText = error.localizedDescription
      alert.runModal()
    }
  }
}
