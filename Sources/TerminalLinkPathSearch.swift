import AppKit
import CmuxTerminalCore
import Foundation

/// Fork: resolves a clicked terminal token that no exact base accounts for, by
/// searching for it by suffix, and asks when the search is ambiguous.
///
/// Terminal text routinely spells a path relative to something the terminal
/// cannot know — a project directory the author had in mind. Exact bases still
/// win outright (the coordinator tries them first), so this only costs a
/// subprocess on clicks that would otherwise have failed.
@MainActor
enum TerminalLinkPathSearch {
    enum Outcome {
        /// Not path-like; continue with URL classification.
        case none
        /// The search found exactly one file.
        case path(String)
        /// The click is consumed: either a disambiguation menu was shown, or the
        /// token is a schemeless, slash-bearing path that does not exist —
        /// handing it to the URL route would just open a browser on nonsense.
        case handled
    }

    static func resolve(
        _ rawText: String,
        cwd: String?,
        request: TerminalLinkOpenRequest,
        container: (any TerminalLinkOpenContainer)?,
        openChoice: @escaping @MainActor (String) -> Void
    ) -> Outcome {
        guard TerminalPathResolver.looksLikeRelativePath(rawText) else { return .none }

        // The pinned files-sidebar root is a strong hint: it usually sits on
        // whatever the current work is, which is the directory such paths tend
        // to be written against.
        var searchRoots: [String] = []
        if let pinned = owningWorkspace(request: request, container: container)?
            .fileExplorerRootOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines), !pinned.isEmpty {
            searchRoots.append(pinned)
        }

        switch TerminalPathResolver().resolveWithSearch(rawText, cwd: cwd, searchRoots: searchRoots) {
        case .none:
            return .handled
        case .single(let path):
            return .path(path)
        case .ambiguous(let paths):
            presentDisambiguationMenu(paths, openChoice: openChoice)
            return .handled
        }
    }

    private static func owningWorkspace(
        request: TerminalLinkOpenRequest,
        container: (any TerminalLinkOpenContainer)?
    ) -> Workspace? {
        if let workspace = container as? Workspace { return workspace }
        guard let panelId = request.sourcePanelId else { return nil }
        return AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelId,
            preferredWorkspaceId: request.sourceWorkspaceId
        )?.workspace
    }

    private static func presentDisambiguationMenu(
        _ paths: [String],
        openChoice: @escaping @MainActor (String) -> Void
    ) {
        let handler = MenuHandler(openChoice: openChoice)
        let menu = NSMenu()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in paths {
            let title = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : Substring(path)
            let item = NSMenuItem(
                title: String(title),
                action: #selector(MenuHandler.choose(_:)),
                keyEquivalent: ""
            )
            item.target = handler
            item.representedObject = path
            menu.addItem(item)
        }
        // popUp tracks synchronously, so `handler` outlives every selection.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private final class MenuHandler: NSObject {
        let openChoice: @MainActor (String) -> Void

        init(openChoice: @escaping @MainActor (String) -> Void) {
            self.openChoice = openChoice
        }

        @MainActor
        @objc func choose(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            openChoice(path)
        }
    }
}
