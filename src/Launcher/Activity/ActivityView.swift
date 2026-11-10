import AppKit
import SwiftUI

/// Expandable operations with native scrolling and keyboard disclosure controls.
struct ActivityView: NSViewRepresentable {
  let operations: [LaunchActivity]

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = ActivityScrollView()
    scroll.drawsBackground = false
    scroll.contentView.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.scrollerStyle = .overlay
    scroll.scrollerKnobStyle = .light
    scroll.autohidesScrollers = true
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.verticalScroller?.controlSize = .small
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

    let outline = NSOutlineView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("activity"))
    column.resizingMask = .autoresizingMask
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.headerView = nil
    outline.style = .plain
    outline.backgroundColor = .clear
    outline.focusRingType = .none
    outline.selectionHighlightStyle = .none
    outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    outline.autoresizingMask = [.width]
    outline.intercellSpacing = .zero
    outline.indentationPerLevel = 12
    outline.dataSource = context.coordinator
    outline.delegate = context.coordinator
    outline.setAccessibilityLabel("Startup activity")
    scroll.documentView = outline
    context.coordinator.outline = outline

    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.update(operations)
  }

  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.timer?.invalidate()
    coordinator.timer = nil
  }

  @MainActor
  final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    fileprivate weak var outline: NSOutlineView?
    fileprivate var timer: Timer?
    private var groups: [ActivityGroup] = []

    deinit { timer?.invalidate() }

    fileprivate func update(_ operations: [LaunchActivity]) {
      guard let outline, groups.map(\.operation) != operations else { return }

      let wasAtBottom = outline.visibleRect.maxY >= outline.bounds.maxY - 1

      // AppKit preserves disclosure for the same objects; new operations start collapsed.
      let existing = Dictionary(uniqueKeysWithValues: groups.map { ($0.operation.id, $0) })
      groups = operations.map { operation in
        if let group = existing[operation.id], group.operation.startedAt == operation.startedAt {
          group.update(operation)
          return group
        }

        return ActivityGroup(operation)
      }

      outline.reloadData()

      // Keep the latest stage header visible unless the user has scrolled up.
      outline.layoutSubtreeIfNeeded()
      if wasAtBottom, let latest = groups.last {
        let row = outline.row(forItem: latest)
        if row >= 0, outline.rect(ofRow: row).maxY > outline.visibleRect.maxY {
          outline.scrollRowToVisible(row)
        }
      }

      if operations.contains(where: { $0.status == .running }) {
        if timer == nil {
          timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshElapsed() }
          }
        }
      } else {
        timer?.invalidate()
        timer = nil
      }
    }

    private func refreshElapsed() {
      guard let outline else { return }

      // Refresh elapsed labels directly rather than reloading the outline every second.
      for group in groups where group.operation.status == .running {
        let row = outline.row(forItem: group)
        guard row >= 0,
          let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ActivityGroupCell else { continue }

        cell.elapsed.stringValue = group.operation.elapsed()
      }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
      item == nil ? groups.count : (item as? ActivityGroup)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
      if let group = item as? ActivityGroup { return group.children[index] }

      return groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
      (item as? ActivityGroup)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
      item is ActivityGroup ? 22 : 18
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
      if let group = item as? ActivityGroup {
        let identifier = NSUserInterfaceItemIdentifier("operation")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? ActivityGroupCell
          ?? ActivityGroupCell()
        cell.identifier = identifier
        cell.configure(group.operation)
        return cell
      }

      guard let detail = item as? ActivityDetail else { return nil }

      let identifier = NSUserInterfaceItemIdentifier("detail")
      let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? ActivityDetailCell
        ?? ActivityDetailCell()
      cell.identifier = identifier
      cell.textField?.stringValue = detail.text
      cell.textField?.textColor = detail.isIssue ? .systemOrange : .white.withAlphaComponent(0.60)
      cell.toolTip = detail.text
      return cell
    }
  }
}

private final class ActivityGroup {
  var operation: LaunchActivity
  var children: [ActivityDetail] = []

  init(_ operation: LaunchActivity) {
    self.operation = operation
    update(operation)
  }

  func update(_ operation: LaunchActivity) {
    self.operation = operation

    let previous = Dictionary(uniqueKeysWithValues: children.filter { !$0.isIssue }.map { ($0.text, $0) })
    children = operation.details.map { previous[$0] ?? ActivityDetail($0) }
    if let message = operation.message { children.append(ActivityDetail(message, isIssue: true)) }
  }
}

private final class ActivityDetail {
  let text: String
  let isIssue: Bool

  init(_ text: String, isIssue: Bool = false) {
    self.text = text
    self.isIssue = isIssue
  }
}

private final class ActivityScrollView: NSScrollView {
  override var scrollerStyle: NSScroller.Style {
    get { super.scrollerStyle }
    set { super.scrollerStyle = .overlay }
  }
}
