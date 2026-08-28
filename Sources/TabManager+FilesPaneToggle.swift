import AppKit
import Bonsplit

extension TabManager {
    /// Fork: show/hide a Files tree as a pane tab (⌃⌘B).
    ///
    /// Adam's layout is terminals on the left and a preview pane on the right,
    /// so the tree opens next to the previews rather than on top of whatever
    /// happens to be focused — hitting the key from a terminal should not bury
    /// the terminal. Every open Files pane closes together, which keeps the
    /// toggle honest when more than one tree is out.
    @discardableResult
    func toggleFilesPane() -> Bool {
        guard let workspace = selectedWorkspace else { return false }

        let openFilesPanelIds = workspace.panels.compactMap { id, panel -> UUID? in
            guard let tool = panel as? RightSidebarToolPanel, tool.mode == .files else { return nil }
            return id
        }
        if !openFilesPanelIds.isEmpty {
            for panelId in openFilesPanelIds {
                _ = workspace.closePanel(panelId, force: true)
            }
            return true
        }

        guard let paneId = filesPaneTarget(in: workspace) else {
            NSSound.beep()
            return false
        }
        workspace.clearSplitZoom()
        return workspace.openOrFocusRightSidebarToolSurface(inPane: paneId, mode: .files, focus: true) != nil
    }

    /// The pane holding the most previews — the mdtab pane in practice. Falls
    /// back to focus (then to any pane) when nothing is previewing anything.
    private func filesPaneTarget(in workspace: Workspace) -> PaneID? {
        let ranked = workspace.bonsplitController.allPaneIds
            .map { paneId -> (PaneID, Int) in
                let previews = workspace.bonsplitController.tabs(inPane: paneId).reduce(into: 0) { count, tab in
                    guard let panelId = workspace.panelIdFromSurfaceId(tab.id),
                          let panel = workspace.panels[panelId] else { return }
                    if panel is MarkdownPanel || panel is FilePreviewPanel { count += 1 }
                }
                return (paneId, previews)
            }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }

        return ranked?.0
            ?? workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
    }
}
