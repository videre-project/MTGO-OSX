import SwiftUI

struct BehaviorSettingsView: View {
  @ObservedObject var settings: LauncherSettings

  var body: some View {
    Form {
      Section("Attention") {
        Picker("Dock indicator", selection: $settings.attentionMode) {
          Text("Off").tag(DockAttentionMode.off)
          Text("Steady badge").tag(DockAttentionMode.steady)
          Text("Pulsing badge").tag(DockAttentionMode.pulsing)
        }
        .pickerStyle(.segmented)
        Text("Marks requests for attention from MTGO while another app is active. Pulsing stops after two cycles; the badge remains until you return to MTGO.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Section("Startup") {
        Toggle("Show progress on routine launches", isOn: $settings.showStartupProgress)
        Text("Installation, updates and errors always show progress.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}
