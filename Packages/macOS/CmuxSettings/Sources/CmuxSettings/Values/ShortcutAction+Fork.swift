/// Fork-only shortcut actions (workspace slots, the hotkey legend, the Files
/// pane toggle, and the markdown edit toggle).
///
/// The app target's `KeyboardShortcutSettings.Action` resolves every binding
/// through ``ShortcutAction`` by raw value, and an action missing here resolves
/// to unbound — so each fork action needs a case in the enum. The metadata lives
/// in this file; upstream's exhaustive switches delegate here with one line.
extension ShortcutAction {
    static let forkActions: [ShortcutAction] = [
        .slotSelect, .slotSelectJot, .nukeWorkspace, .banishWorkspace,
        .unbanishAllWorkspaces, .toggleHotkeyLegend, .toggleFilesPane,
        .toggleMarkdownEditMode,
    ]

    var forkDisplayName: String {
        switch self {
        case .slotSelect: return "Workspace Slot 1…9"
        case .slotSelectJot: return "Workspace Slot 0 (Planning)"
        case .nukeWorkspace: return "Nuke Focused Workspace"
        case .banishWorkspace: return "Banish Focused Workspace"
        case .unbanishAllWorkspaces: return "Unbanish All Workspaces"
        case .toggleHotkeyLegend: return "Toggle Hotkey Legend"
        case .toggleFilesPane: return "File Explorer: Toggle Files Pane"
        case .toggleMarkdownEditMode: return "Markdown: Toggle Edit/Preview (Saves)"
        default: return rawValue
        }
    }

    /// Mirrors the fork rows in `Sources/KeyboardShortcutSettings.swift`.
    var forkDefaultStroke: ShortcutStroke? {
        switch self {
        case .slotSelect: return ShortcutStroke(key: "1", command: true)
        case .slotSelectJot: return ShortcutStroke(key: "0", command: true)
        case .nukeWorkspace: return ShortcutStroke(key: "\u{7F}", command: true, shift: true)
        case .banishWorkspace: return ShortcutStroke(key: "b", command: true, shift: true)
        case .unbanishAllWorkspaces: return ShortcutStroke(key: "u", command: true, shift: true)
        case .toggleHotkeyLegend: return ShortcutStroke(key: "/", command: true)
        case .toggleFilesPane: return ShortcutStroke(key: "b", command: true, control: true)
        case .toggleMarkdownEditMode: return ShortcutStroke(key: "e", option: true, control: true)
        default: return nil
        }
    }

    var forkGroup: Group {
        switch self {
        case .toggleFilesPane: return .panes
        case .toggleMarkdownEditMode: return .browser
        default: return .workspace
        }
    }
}
