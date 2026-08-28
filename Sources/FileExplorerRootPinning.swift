import AppKit
import Foundation

/// Sets the files-sidebar root from the UI, the same pin the CLI's
/// `cmux right-sidebar set-root` writes.
///
/// Both go through `Workspace.fileExplorerRootOverride`, which `ContentView`
/// observes to re-apply the explorer root — so a menu click and a CLI call are
/// the same operation and cannot drift apart. Passing `nil` clears the override
/// and hands the sidebar back to shell-cwd auto-follow.
///
/// Files *panes* deliberately do not come through here: each owns its own root
/// (`RightSidebarToolPanel.setFileExplorerRootOverride`) so retargeting one
/// leaves the sidebar and every other pane where they were.
enum FileExplorerRootPinning {
    @MainActor
    static func setRoot(_ path: String?, workspaceId: UUID?) {
        guard let workspaceId,
              let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == workspaceId })
        else { return }
        guard !workspace.isRemoteWorkspace else { return }

        guard let path else {
            workspace.fileExplorerRootOverride = nil
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return }
        workspace.fileExplorerRootOverride = path
    }

    /// Ancestor directories of `path`, nearest first, for the header breadcrumb.
    ///
    /// Stops at `$HOME` (and always at `/`) rather than walking the whole way up:
    /// the levels above home are never a useful sidebar root, and an unbounded
    /// list turns the menu into a wall of noise in a narrow sidebar.
    static func ancestors(of path: String, limit: Int = 8) -> [String] {
        guard path.hasPrefix("/") else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var result: [String] = []
        var current = (path as NSString).standardizingPath

        while result.count < limit {
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, !parent.isEmpty, parent != "." else { break }
            result.append(parent)
            if parent == home || parent == "/" { break }
            current = parent
        }
        return result
    }
}

/// The last few directories the files sidebar was pinned to, newest first.
///
/// Deliberately app-global rather than per-workspace: the point is hopping to a
/// reference folder somewhere else in the tree — notes, another project — from
/// whatever workspace happens to be in front. A per-workspace list would be empty
/// in exactly the workspace where you want it.
///
/// Persisted in `UserDefaults` so the list survives a restart, and re-filtered on
/// read so a folder that has since been deleted or renamed never shows up.
enum FileExplorerRecentRoots {
    static let limit = 5
    private static let defaultsKey = "fileExplorer.recentRoots"

    static func record(_ path: String, defaults: UserDefaults = .standard) {
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix("/") else { return }
        var entries = stored(defaults: defaults)
        entries.removeAll { $0 == standardized }
        entries.insert(standardized, at: 0)
        defaults.set(Array(entries.prefix(limit)), forKey: defaultsKey)
    }

    /// Recents that still exist as directories, excluding `current` — offering the
    /// root you are already on is a dead menu entry.
    static func list(excluding current: String? = nil, defaults: UserDefaults = .standard) -> [String] {
        let currentStandardized = current.map { ($0 as NSString).standardizingPath }
        return stored(defaults: defaults).filter { path in
            guard path != currentStandardized else { return false }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    }

    private static func stored(defaults: UserDefaults) -> [String] {
        (defaults.array(forKey: defaultsKey) as? [String]) ?? []
    }
}
