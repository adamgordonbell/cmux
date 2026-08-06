import AppKit
import Foundation

/// Sets the files-sidebar root from the UI, the same pin the CLI's
/// `cmux right-sidebar set-root` writes.
///
/// Both go through `Workspace.fileExplorerRootOverride`, which `ContentView`
/// observes to re-apply the explorer root — so a menu click and a CLI call are
/// the same operation and cannot drift apart. Passing `nil` clears the override
/// and hands the sidebar back to shell-cwd auto-follow.
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
