import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the three things that make a Files pane an independent view of the
/// tree rather than a second window onto the sidebar's: it can be opened more
/// than once, it owns its root, and it does not fight the sidebar over which
/// explorer a mode-targeted focus request reaches.
@MainActor
struct FileExplorerPaneIndependenceTests {

    // MARK: - Helpers

    private func makeContainer(presentation: FileExplorerPanelPresentation) -> FileExplorerContainerView {
        let coordinator = FileExplorerPanelView.Coordinator(
            store: FileExplorerStore(),
            state: FileExplorerState(),
            onOpenFilePreview: { _ in }
        )
        return FileExplorerContainerView(coordinator: coordinator, presentation: presentation)
    }

    private func makeFocusController() -> MainWindowFocusController {
        MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState()
        )
    }

    private func makeTemporaryDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-files-pane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    // MARK: - Focus host registry

    @Test func newestRegisteredHostIsActiveAndRelayoutDoesNotReorder() throws {
#if DEBUG
        let controller = makeFocusController()
        let first = makeContainer(presentation: .files)
        let second = makeContainer(presentation: .files)

        controller.registerFileExplorerHost(first)
        controller.registerFileExplorerHost(second)
        #expect(controller.fileExplorerHostCountForTesting() == 2)
        #expect(controller.activeFileExplorerHostForTesting(mode: .files) === second)

        // `layout()` re-registers on every pass; that must not hand the active
        // slot back to whichever view happened to lay out most recently.
        controller.registerFileExplorerHost(first)
        controller.registerFileExplorerHost(first)
        #expect(controller.fileExplorerHostCountForTesting() == 2)
        #expect(controller.activeFileExplorerHostForTesting(mode: .files) === second)
#endif
    }

    @Test func hostsAreTrackedPerMode() throws {
#if DEBUG
        let controller = makeFocusController()
        let files = makeContainer(presentation: .files)
        let find = makeContainer(presentation: .find)

        controller.registerFileExplorerHost(files)
        controller.registerFileExplorerHost(find)

        #expect(controller.activeFileExplorerHostForTesting(mode: .files) === files)
        #expect(controller.activeFileExplorerHostForTesting(mode: .find) === find)
#endif
    }

    @Test func responderOwnershipPromotesHostToActive() throws {
#if DEBUG
        let controller = makeFocusController()
        let first = makeContainer(presentation: .files)
        let second = makeContainer(presentation: .files)

        controller.registerFileExplorerHost(first)
        controller.registerFileExplorerHost(second)
        #expect(controller.activeFileExplorerHostForTesting(mode: .files) === second)

        // The responder chain is the authority on where the user actually is.
        #expect(controller.ownsRightSidebarFocus(first.searchResultsView))
        #expect(controller.activeFileExplorerHostForTesting(mode: .files) === first)
#endif
    }

    @Test func unregisteringActiveHostFallsBackToTheOtherOne() throws {
#if DEBUG
        let controller = makeFocusController()
        let first = makeContainer(presentation: .files)
        let second = makeContainer(presentation: .files)

        controller.registerFileExplorerHost(first)
        controller.registerFileExplorerHost(second)
        controller.unregisterFileExplorerHost(second)

        #expect(controller.fileExplorerHostCountForTesting() == 1)
        #expect(controller.activeFileExplorerHostForTesting(mode: .files) === first)

        controller.unregisterFileExplorerHost(first)
        #expect(controller.fileExplorerHostCountForTesting() == 0)
        #expect(controller.activeFileExplorerHostForTesting(mode: .files) == nil)
        #expect(!controller.ownsRightSidebarFocus(first.searchResultsView))
#endif
    }

    // MARK: - Multiple Files panes

    @Test func filesPanesStackWhileOtherToolsFocusTheExistingPane() throws {
        let workspace = Workspace()
        guard let pane = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first else {
            Issue.record("Workspace had no pane to open into")
            return
        }

        let firstFiles = workspace.openOrFocusRightSidebarToolSurface(inPane: pane, mode: .files, focus: false)
        let secondFiles = workspace.openOrFocusRightSidebarToolSurface(inPane: pane, mode: .files, focus: false)
        #expect(firstFiles != nil)
        #expect(secondFiles != nil)
        #expect(firstFiles?.id != secondFiles?.id)

        let firstFind = workspace.openOrFocusRightSidebarToolSurface(inPane: pane, mode: .find, focus: false)
        let secondFind = workspace.openOrFocusRightSidebarToolSurface(inPane: pane, mode: .find, focus: false)
        #expect(firstFind != nil)
        #expect(firstFind?.id == secondFind?.id)

        let firstVault = workspace.openOrFocusRightSidebarToolSurface(inPane: pane, mode: .sessions, focus: false)
        let secondVault = workspace.openOrFocusRightSidebarToolSurface(inPane: pane, mode: .sessions, focus: false)
        #expect(firstVault != nil)
        #expect(firstVault?.id == secondVault?.id)
    }

    // MARK: - Per-panel root

    @Test func panelRootOverrideRetargetsOnlyThatPanel() throws {
        let recentRootsKey = "fileExplorer.recentRoots"
        let previousRecents = UserDefaults.standard.object(forKey: recentRootsKey)
        defer {
            if let previousRecents {
                UserDefaults.standard.set(previousRecents, forKey: recentRootsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: recentRootsKey)
            }
        }

        let shellDirectory = try makeTemporaryDirectory()
        let pinnedDirectory = try makeTemporaryDirectory()

        let workspace = Workspace()
        workspace.currentDirectory = shellDirectory

        let pinned = RightSidebarToolPanel(workspace: workspace, mode: .files)
        let following = RightSidebarToolPanel(workspace: workspace, mode: .files)
        #expect(pinned.fileExplorerStore.rootPath == shellDirectory)
        #expect(following.fileExplorerStore.rootPath == shellDirectory)

        pinned.setFileExplorerRootOverride(pinnedDirectory)
        #expect(pinned.fileExplorerRootOverride == pinnedDirectory)
        #expect(pinned.fileExplorerStore.rootPath == pinnedDirectory)
        // The point of the whole exercise: the other pane did not move.
        #expect(following.fileExplorerStore.rootPath == shellDirectory)
        #expect(workspace.fileExplorerRootOverride == nil)

        // A pinned pane stops following the shell.
        let movedDirectory = try makeTemporaryDirectory()
        workspace.currentDirectory = movedDirectory
        pinned.syncWorkspaceRoot(from: workspace)
        following.syncWorkspaceRoot(from: workspace)
        #expect(pinned.fileExplorerStore.rootPath == pinnedDirectory)
        #expect(following.fileExplorerStore.rootPath == movedDirectory)

        // Clearing hands it back to the shell cwd.
        pinned.setFileExplorerRootOverride(nil)
        #expect(pinned.fileExplorerRootOverride == nil)
        #expect(pinned.fileExplorerStore.rootPath == movedDirectory)
    }

    @Test func panelRootOverrideRejectsNonDirectories() throws {
        let shellDirectory = try makeTemporaryDirectory()
        let workspace = Workspace()
        workspace.currentDirectory = shellDirectory

        let panel = RightSidebarToolPanel(workspace: workspace, mode: .files)
        panel.setFileExplorerRootOverride("/definitely/not/a/real/directory")
        panel.setFileExplorerRootOverride("relative/path")

        #expect(panel.fileExplorerRootOverride == nil)
        #expect(panel.fileExplorerStore.rootPath == shellDirectory)
    }
}
