import AppKit
import SwiftUI

/// Native toolbar navigation that remembers the last settings pane.
@MainActor
final class SettingsWindow: NSWindow {
  init(session: LauncherSession, defaults: UserDefaults = .standard, restartSession: @escaping () -> Void) {
    super.init(
      contentRect: NSRect(origin: .zero, size: LauncherSettingsView.size),
      styleMask: [.titled, .closable], backing: .buffered, defer: false
    )

    // Adding the first tab selects it, so read the saved pane before creating tabs.
    let selected = defaults.string(forKey: "settingsPane").flatMap(LauncherSettingsView.Pane.init(rawValue:)) ?? .appearance
    let tabs = SettingsTabs(defaults: defaults)
    tabs.tabStyle = .toolbar
    for pane in LauncherSettingsView.Pane.allCases {
      let controller = NSHostingController(rootView: LauncherSettingsView(
        pane: pane, session: session, restartSession: restartSession
      ))
      let item = NSTabViewItem(viewController: controller)
      item.identifier = pane.rawValue
      item.label = pane.title
      item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
      tabs.addTabViewItem(item)
    }

    tabs.selectedTabViewItemIndex = LauncherSettingsView.Pane.allCases.firstIndex(of: selected) ?? 0
    tabs.preferredContentSize = LauncherSettingsView.size
    contentViewController = tabs
    setContentSize(tabs.preferredContentSize)
    toolbarStyle = .preference
    title = selected.title
    isReleasedWhenClosed = false
    center()
  }
}

@MainActor
private final class SettingsTabs: NSTabViewController {
  private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)
    guard let name = tabViewItem?.identifier as? String,
      let pane = LauncherSettingsView.Pane(rawValue: name) else { return }

    defaults.set(name, forKey: "settingsPane")
    view.window?.title = pane.title
  }
}
