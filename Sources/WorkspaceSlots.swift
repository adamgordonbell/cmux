import AppKit
import Bonsplit
import CmuxWorkspaces
import Foundation

/// Numbered workspace "slots" — fixed hotkey targets with self-healing roles.
///
/// Slot semantics (ported from the external cmux-slot overlay, see the fork
/// plan): slot 0 = the jot pad (first tab of the planning workspace), slot 1 =
/// the planning Claude session, slots 2–9 = the visible non-planning
/// workspaces in sidebar order. Slots 0/1 self-heal: if the role's process is
/// not actually running on the surface's tty, the configured command is
/// relaunched in place (the surface is created first if it was closed).
///
/// Slot order is derived from the same workspace array the sidebar renders,
/// scoped to one window, excluding banished-group members — so the number you
/// press always matches what you see, by construction.
///
/// Configuration lives in `~/.config/cmux/slots.json` (separate from
/// cmux.json so the strict config validator and the release app never see
/// it):
///
/// ```json
/// {
///   "enabled": true,
///   "planningName": "planning",
///   "slot0": { "titleContains": "jot pad", "command": "~/para/scripts/jot/jot", "pinFirst": true },
///   "slot1": { "command": "cd ~/para/periodic && claude" },
///   "scratch": { "command": "cc-pick", "cwd": "~/para" },
///   "processName": "claude"
/// }
/// ```
@MainActor
enum WorkspaceSlots {
    static let banishedGroupName = "📦 banished"

    // MARK: - Settings

    struct SlotRole: Codable {
        var titleContains: String?
        var command: String
        var pinFirst: Bool?
    }

    struct ScratchRole: Codable {
        var command: String?
        var cwd: String?
    }

    struct Settings: Codable {
        var enabled: Bool = false
        var planningName: String = "planning"
        var slot0: SlotRole?
        var slot1: SlotRole?
        var scratch: ScratchRole?
        /// Process name whose presence on the surface's tty counts as "alive"
        /// for the self-heal check.
        var processName: String = "claude"

        private enum CodingKeys: String, CodingKey {
            case enabled, planningName, slot0, slot1, scratch, processName
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            planningName = try c.decodeIfPresent(String.self, forKey: .planningName) ?? "planning"
            slot0 = try c.decodeIfPresent(SlotRole.self, forKey: .slot0)
            slot1 = try c.decodeIfPresent(SlotRole.self, forKey: .slot1)
            scratch = try c.decodeIfPresent(ScratchRole.self, forKey: .scratch)
            processName = try c.decodeIfPresent(String.self, forKey: .processName) ?? "claude"
        }
    }

    private static var cachedSettings: Settings?
    private static var cachedSettingsModified: Date?

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/slots.json")
    }

    static func settings() -> Settings {
        let url = settingsURL
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if let cachedSettings, cachedSettingsModified == modified {
            return cachedSettings
        }
        var loaded = Settings()
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONDecoder().decode(Settings.self, from: data) {
            loaded = parsed
        }
        cachedSettings = loaded
        cachedSettingsModified = modified
        return loaded
    }

    static var isEnabled: Bool { settings().enabled }

    // MARK: - Slot resolution

    static func planningWorkspace(in tabManager: TabManager) -> Workspace? {
        let name = settings().planningName.lowercased()
        return tabManager.tabs.first {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name
        }
    }

    private static func banishedGroup(in tabManager: TabManager) -> WorkspaceGroup? {
        tabManager.workspaceGroups.first { $0.name == banishedGroupName }
    }

    /// The workspaces slots 2–9 index into: sidebar order, minus planning,
    /// minus everything parked in the banished group (members AND anchor).
    static func slotWorkspaces(in tabManager: TabManager) -> [Workspace] {
        let planningId = planningWorkspace(in: tabManager)?.id
        let banished = banishedGroup(in: tabManager)
        return tabManager.tabs.filter { ws in
            if ws.id == planningId { return false }
            if let banished {
                if ws.groupId == banished.id { return false }
                if ws.id == banished.anchorWorkspaceId { return false }
            }
            return true
        }
    }

    // MARK: - Actions

    enum SelectOutcome {
        case focused(workspaceID: UUID, surfaceID: UUID?)
        case createdScratch(workspaceID: UUID?)
        case healed(workspaceID: UUID, surfaceID: UUID?)
        case planningMissing
        case failed(String)
    }

    @discardableResult
    static func select(_ slot: Int, tabManager: TabManager) -> SelectOutcome {
        guard (0...9).contains(slot) else { return .failed("slot out of range") }
        if slot <= 1 {
            return selectPlanningSlot(slot, tabManager: tabManager)
        }
        let scratch = slotWorkspaces(in: tabManager)
        let position = slot - 2
        if position < scratch.count {
            let ws = scratch[position]
            tabManager.selectTab(ws)
            return .focused(workspaceID: ws.id, surfaceID: nil)
        }
        // Beyond the end: spin up a fresh scratch workspace.
        let cfg = settings().scratch
        let cwd = expandPath(cfg?.cwd ?? "~/para")
        let command = cfg?.command ?? "cc-pick"
        let ws = tabManager.addWorkspace(
            title: "scratch \(scratch.count + 1)",
            workingDirectory: cwd,
            initialTerminalCommand: command,
            select: true
        )
        return .createdScratch(workspaceID: ws.id)
    }

    private static func selectPlanningSlot(_ slot: Int, tabManager: TabManager) -> SelectOutcome {
        guard let planning = planningWorkspace(in: tabManager) else { return .planningMissing }
        tabManager.selectTab(planning)

        let cfg = settings()
        let role: SlotRole = (slot == 0)
            ? (cfg.slot0 ?? SlotRole(titleContains: "jot pad", command: "~/para/scripts/jot/jot", pinFirst: true))
            : (cfg.slot1 ?? SlotRole(titleContains: nil, command: "cd ~/para/periodic && claude", pinFirst: false))

        let terminals = terminalPanels(in: planning)
        let jot = terminals.first { panelTitle($0, in: planning).lowercased().contains("jot pad") }
        let target: TerminalPanel?
        if slot == 0 {
            target = jot
        } else {
            let others = terminals.filter { $0 !== jot }
            target = others.first { claudeIshTitle(panelTitle($0, in: planning)) } ?? others.first
        }

        if let target, processAlive(cfg.processName, onTTY: planning.surfaceTTYNames[target.id]) {
            focus(panelId: target.id, in: planning, tabManager: tabManager)
            return .focused(workspaceID: planning.id, surfaceID: target.id)
        }

        // Heal: reuse the dead shell if the surface exists, else create one in
        // the leftmost pane.
        let command = expandPath(role.command)
        let healedPanelId: UUID?
        if let target {
            _ = target.sendInputResult(command + "\r")
            healedPanelId = target.id
        } else {
            let pane = leftmostPane(in: planning)
            let created = planning.newTerminalSurface(
                inPane: pane,
                focus: true,
                initialCommand: command
            )
            healedPanelId = created?.id
        }
        guard let healedPanelId else {
            return .failed("could not create a terminal in the planning workspace")
        }
        if role.pinFirst == true {
            let pane = planning.paneId(forPanelId: healedPanelId) ?? leftmostPane(in: planning)
            _ = planning.moveSurface(panelId: healedPanelId, toPane: pane, atIndex: 0, focus: true)
        }
        focus(panelId: healedPanelId, in: planning, tabManager: tabManager)
        return .healed(workspaceID: planning.id, surfaceID: healedPanelId)
    }

    enum NukeOutcome {
        case nuked(workspaceID: UUID)
        case refusedPlanning
        case nothingFocused
    }

    @discardableResult
    static func nukeFocused(tabManager: TabManager) -> NukeOutcome {
        guard let selectedId = tabManager.selectedTabId,
              let ws = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            return .nothingFocused
        }
        if ws.id == planningWorkspace(in: tabManager)?.id {
            return .refusedPlanning
        }
        tabManager.closeWorkspace(ws)
        return .nuked(workspaceID: ws.id)
    }

    enum BanishOutcome {
        case banished(workspaceID: UUID)
        case refused(String)
        case nothingFocused
    }

    /// Park the focused workspace in a collapsed sidebar group. It leaves the
    /// slot order (see `slotWorkspaces`) but keeps running.
    @discardableResult
    static func banishFocused(tabManager: TabManager) -> BanishOutcome {
        guard let selectedId = tabManager.selectedTabId,
              let ws = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            return .nothingFocused
        }
        if ws.id == planningWorkspace(in: tabManager)?.id {
            return .refused("refusing to banish the planning workspace")
        }
        if tabManager.workspaceGroups.contains(where: { $0.anchorWorkspaceId == ws.id }) {
            return .refused("workspace anchors a group; ungroup it first")
        }

        // Land somewhere visible before the workspace disappears into the
        // collapsed group: planning if present, else the next visible slot.
        let fallback = planningWorkspace(in: tabManager)
            ?? slotWorkspaces(in: tabManager).first { $0.id != ws.id }

        if let group = banishedGroup(in: tabManager) {
            tabManager.addWorkspaceToGroup(workspaceId: ws.id, groupId: group.id)
            tabManager.setWorkspaceGroupCollapsed(groupId: group.id, isCollapsed: true)
        } else {
            guard let groupId = tabManager.createWorkspaceGroup(
                name: banishedGroupName,
                childWorkspaceIds: [ws.id],
                selectAnchor: false,
                collapseSidebarSelection: false
            ) else {
                return .refused("could not create the banished group")
            }
            tabManager.setWorkspaceGroupCollapsed(groupId: groupId, isCollapsed: true)
        }
        if let fallback {
            tabManager.selectTab(fallback)
        }
        return .banished(workspaceID: ws.id)
    }

    enum UnbanishOutcome {
        case unbanished(count: Int)
        case noGroup
    }

    /// Bring every parked workspace back into the visible sidebar. The group
    /// (and its anchor workspace) stays for reuse.
    @discardableResult
    static func unbanishAll(tabManager: TabManager) -> UnbanishOutcome {
        guard let group = banishedGroup(in: tabManager) else { return .noGroup }
        let members = tabManager.tabs.filter {
            $0.groupId == group.id && $0.id != group.anchorWorkspaceId
        }
        for ws in members {
            tabManager.removeWorkspaceFromGroup(workspaceId: ws.id)
        }
        return .unbanished(count: members.count)
    }

    // MARK: - Helpers

    private static func terminalPanels(in ws: Workspace) -> [TerminalPanel] {
        // Iterate in bonsplit tab order so "first tab" semantics hold.
        var result: [TerminalPanel] = []
        for paneId in ws.bonsplitController.allPaneIds {
            for tab in ws.bonsplitController.tabs(inPane: paneId) {
                if let panelId = ws.panelIdFromSurfaceId(tab.id),
                   let panel = ws.panels[panelId] as? TerminalPanel {
                    result.append(panel)
                }
            }
        }
        return result
    }

    private static func panelTitle(_ panel: TerminalPanel, in ws: Workspace) -> String {
        // Prefer the bonsplit tab title (what the user sees, incl. renames);
        // fall back to the panel's own title.
        if let surfaceId = ws.surfaceIdFromPanelId(panel.id) {
            for paneId in ws.bonsplitController.allPaneIds {
                if let tab = ws.bonsplitController.tabs(inPane: paneId).first(where: { $0.id == surfaceId }) {
                    return tab.title
                }
            }
        }
        return panel.title
    }

    /// A Claude Code surface titles itself with a leading ✳ (idle) or a
    /// braille spinner (while working).
    private static func claudeIshTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard let first = t.unicodeScalars.first else { return false }
        if first == "✳" { return true }
        if (0x2800...0x28FF).contains(Int(first.value)) { return true }
        return t.lowercased().contains("claude code")
    }

    /// The renderer-independent liveness test: is the configured process
    /// actually running on this surface's tty? A restored bare shell has only
    /// zsh — no claude.
    private static func processAlive(_ name: String, onTTY tty: String?) -> Bool {
        guard let tty, !tty.isEmpty else { return false }
        let short = tty.components(separatedBy: "/").last ?? tty
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-t", short, "-o", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return false }
        return out.split(separator: "\n").contains { line in
            let comm = line.trimmingCharacters(in: .whitespaces)
            return (comm.components(separatedBy: "/").last ?? comm) == name
        }
    }

    /// When the planning workspace is split, new jot/Claude tabs go in the
    /// LEFTMOST pane (smallest x in the layout snapshot).
    private static func leftmostPane(in ws: Workspace) -> PaneID {
        let paneIds = ws.bonsplitController.allPaneIds
        guard paneIds.count > 1 else {
            return paneIds.first ?? ws.bonsplitController.focusedPaneId ?? PaneID()
        }
        let snapshot = ws.bonsplitController.layoutSnapshot()
        let frameByPane = Dictionary(
            snapshot.panes.map { ($0.paneId, $0.frame) },
            uniquingKeysWith: { first, _ in first }
        )
        return paneIds.min { a, b in
            (frameByPane[a.id.uuidString]?.x ?? 0) < (frameByPane[b.id.uuidString]?.x ?? 0)
        } ?? paneIds[0]
    }

    private static func focus(panelId: UUID, in ws: Workspace, tabManager: TabManager) {
        if let surfaceId = ws.surfaceIdFromPanelId(panelId),
           let paneId = ws.paneId(forPanelId: panelId) {
            ws.bonsplitController.focusPane(paneId)
            ws.bonsplitController.selectTab(surfaceId)
        }
        ws.focusPanel(panelId)
    }

    private static func expandPath(_ raw: String) -> String {
        (raw as NSString).expandingTildeInPath
    }
}

// MARK: - Control-socket handlers (cmux slot ...)

extension TerminalController {
    private func slotsTabManager() -> TabManager? {
        tabManager
    }

    func v2SlotsSelect(params: [String: Any]) -> V2CallResult {
        guard let tabManager = slotsTabManager() else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let slot = params["slot"] as? Int, (0...9).contains(slot) else {
            return .err(code: "invalid_params", message: "Missing or invalid 'slot' (0-9)", data: nil)
        }
        func payload(_ action: String, _ wsId: UUID?, _ surfId: UUID?) -> [String: Any] {
            var out: [String: Any] = ["action": action]
            if let wsId { out["workspace_id"] = wsId.uuidString }
            if let surfId { out["surface_id"] = surfId.uuidString }
            return out
        }
        switch WorkspaceSlots.select(slot, tabManager: tabManager) {
        case .focused(let wsId, let surfId):
            return .ok(payload("focused", wsId, surfId))
        case .healed(let wsId, let surfId):
            return .ok(payload("healed", wsId, surfId))
        case .createdScratch(let wsId):
            return .ok(payload("created_scratch", wsId, nil))
        case .planningMissing:
            return .err(
                code: "not_found",
                message: "No '\(WorkspaceSlots.settings().planningName)' workspace found",
                data: nil
            )
        case .failed(let message):
            return .err(code: "internal_error", message: message, data: nil)
        }
    }

    func v2SlotsNuke(params: [String: Any]) -> V2CallResult {
        guard let tabManager = slotsTabManager() else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        switch WorkspaceSlots.nukeFocused(tabManager: tabManager) {
        case .nuked(let wsId):
            return .ok(["action": "nuked", "workspace_id": wsId.uuidString])
        case .refusedPlanning:
            return .err(code: "refused", message: "Refusing to nuke the planning workspace", data: nil)
        case .nothingFocused:
            return .err(code: "not_found", message: "No focused workspace", data: nil)
        }
    }

    func v2SlotsBanish(params: [String: Any]) -> V2CallResult {
        guard let tabManager = slotsTabManager() else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        switch WorkspaceSlots.banishFocused(tabManager: tabManager) {
        case .banished(let wsId):
            return .ok(["action": "banished", "workspace_id": wsId.uuidString])
        case .refused(let message):
            return .err(code: "refused", message: message, data: nil)
        case .nothingFocused:
            return .err(code: "not_found", message: "No focused workspace", data: nil)
        }
    }

    func v2SlotsUnbanishAll(params: [String: Any]) -> V2CallResult {
        guard let tabManager = slotsTabManager() else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        switch WorkspaceSlots.unbanishAll(tabManager: tabManager) {
        case .unbanished(let count):
            return .ok(["action": "unbanished", "count": count])
        case .noGroup:
            return .ok(["action": "unbanished", "count": 0])
        }
    }
}
