import SwiftUI

/// Bottom-of-sidebar legend for the workspace-slot hotkeys (fork feature,
/// active only when slots are enabled — see `WorkspaceSlots`).
///
/// Replaces the external Hammerspoon canvas HUD: it lives inside the sidebar
/// view tree, so there is no AX polling, no window-frame chasing, and no
/// occlusion weirdness — it appears and disappears with the sidebar by
/// construction. Rows are generated from the live shortcut settings, so
/// rebinding a key in Settings updates the legend.
@MainActor
final class HotkeyLegendState: ObservableObject {
    static let shared = HotkeyLegendState()

    private static let defaultsKey = "cmux.hotkeyLegend.visible"

    @Published var isVisible: Bool {
        didSet { UserDefaults.standard.set(isVisible, forKey: Self.defaultsKey) }
    }

    private init() {
        isVisible = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    func toggle() { isVisible.toggle() }
}

struct HotkeyLegendPanel: View {
    @ObservedObject private var state = HotkeyLegendState.shared

    private struct Row: Identifiable {
        let keys: String
        let label: String
        var id: String { keys + label }
    }

    private var rows: [Row] {
        let actions: [(KeyboardShortcutSettings.Action, String)] = [
            (.slotSelectJot, "jot pad"),
            (.slotSelect, "slots · 1 plan · 2–9 scratch"),
            (.nukeWorkspace, "nuke workspace"),
            (.banishWorkspace, "banish"),
            (.unbanishAllWorkspaces, "unbanish all"),
            (.toggleHotkeyLegend, "this legend"),
        ]
        var out: [Row] = actions.compactMap { action, label in
            let shortcut = KeyboardShortcutSettings.shortcut(for: action)
            guard !shortcut.isUnbound else { return nil }
            return Row(keys: action.displayedShortcutString(for: shortcut), label: label)
        }
        // Not a configurable Action (markdown panel handles it internally),
        // but part of the working set the old HUD listed.
        out.append(Row(keys: "⌃⌥E", label: "markdown edit/preview"))
        return out
    }

    var body: some View {
        if WorkspaceSlots.isEnabled, state.isVisible {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.keys)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 58, alignment: .leading)
                        Text(row.label)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }
}
