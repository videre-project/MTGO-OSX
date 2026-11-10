import AppKit
import SwiftUI

struct RuntimeSettingsView: View {
  @ObservedObject var settings: LauncherSettings

  private var runtimeStorageFolder: URL {
    if settings.usesCustomRuntime, let folder = settings.runtimeFolder { return folder }
    return settings.runtimeDirectory
  }

  private var version: String {
    if settings.usesCustomRuntime { return "Custom build" }
    guard let catalog = settings.runtimeCatalog, let package = try? RuntimePackage.load(catalog: catalog) else {
      return "Not available"
    }
    return package.version
  }

  var body: some View {
    Form {
      Section("Runtime") {
        LabeledContent("Version", value: version)
        LabeledContent("Architecture", value: RuntimeArchitecture.native == .arm64 ? "Apple silicon (ARM64)" : "Intel (x86_64)")
        Picker("Rendering", selection: $settings.softwareRendering) {
          Text("Hardware").tag(false)
          Text("Software").tag(true)
        }
        .pickerStyle(.segmented)
        Text("Software rendering can avoid graphics issues, but disables foil effects.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      userDataSettings

      Section("Storage") {
        StorageRow(title: "Runtime", folder: runtimeStorageFolder)
        StorageRow(title: "MTGO installation", folder: settings.prefixFolder)
        StorageRow(title: "Downloaded installers", folder: settings.packageCache)
      }

      DisclosureGroup("Advanced") {
        folderRow("Wine runtime", url: settings.runtimeFolder, placeholder: "Downloaded automatically") {
          chooseFolder(title: "Choose a macOS Wine runtime", select: settings.selectRuntime)
        }
        if settings.usesCustomRuntime {
          Button("Use Automatic Runtime", action: settings.useAutomaticRuntime)
        }
        folderRow("Wine prefix", url: settings.prefixFolder) {
          chooseFolder(title: "Choose a Wine prefix directory", select: settings.selectPrefix)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var userDataSettings: some View {
    Section("User data") {
      folderRow("Folder", url: settings.userDataDirectory, action: chooseUserData)
      HStack {
        Button("Show in Finder") {
          NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: settings.userDataDirectory.path)
        }
        .disabled(!FileManager.default.fileExists(atPath: settings.userDataDirectory.path))
        if settings.userDataFolder != nil {
          Button("Use Default Folder", action: settings.useDefaultUserData)
        }
      }
      Text("Stores game history, settings and cached logs. Existing files are copied when this changes. Restart MTGO to apply.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  private func chooseUserData() {
    chooseFolder(title: "Choose an MTGO user data folder") { folder in
      do {
        try settings.selectUserData(folder)
      } catch {
        let alert = NSAlert()
        alert.messageText = "Could not select the user data folder"
        alert.informativeText = error.localizedDescription
        alert.runModal()
      }
    }
  }

  private func folderRow(_ title: String, url: URL?, placeholder: String = "Not selected", action: @escaping () -> Void) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
        Text(url?.path ?? placeholder)
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
      Spacer()
      Button("Choose…", action: action)
    }
  }

  private func chooseFolder(title: String, select: (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { select(url) }
  }
}

/// Measures each folder independently when its path changes.
private struct StorageRow: View {
  let title: String
  let folder: URL
  @State private var size: String?

  var body: some View {
    HStack {
      Text(title)
      Spacer()
      Text(size ?? "Calculating…")
        .foregroundColor(.secondary)
      Button("Show") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path) }
        .disabled(!FileManager.default.fileExists(atPath: folder.path))
    }
    .task(id: folder) {
      size = nil
      let bytes = await StorageUsage.size(of: folder)
      guard !Task.isCancelled else { return }

      size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Not available"
    }
  }
}
