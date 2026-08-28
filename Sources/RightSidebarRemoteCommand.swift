import AppKit
import Foundation

struct RightSidebarRemoteTarget: Equatable, Sendable {
    var windowId: UUID? = nil
    var workspaceId: UUID? = nil

    var isActiveTarget: Bool {
        windowId == nil && workspaceId == nil
    }
}

extension FileExplorerState {
    var rightSidebarRemoteModeRawValue: String {
        mode.rawValue
    }
}

enum RightSidebarRemoteCommand: Equatable, Sendable {
    case toggle
    case show
    case hide
    case focus
    case setMode(RightSidebarMode, focus: Bool)
    // nil clears the override back to following the shell cwd.
    case setFilesRoot(String?)
    // Opens the tool as a pane surface. `paneId` nil means the focused pane.
    case openPane(RightSidebarMode, paneId: UUID?, focus: Bool)
    case getState
}

struct RightSidebarRemoteRequest: Equatable, Sendable {
    let command: RightSidebarRemoteCommand
    let target: RightSidebarRemoteTarget
}

struct RightSidebarRemoteParseError: Error, Equatable, Sendable {
    let message: String
}

struct RightSidebarRemoteState: Equatable, Sendable {
    let visible: Bool
    let modeRawValue: String
}

/// Identifies a surface the app just created, in the app's own UUID terms; the
/// socket layer is what turns these into `surface:`/`pane:` handle refs.
struct RightSidebarRemoteSurface: Equatable, Sendable {
    let workspaceId: UUID
    let paneId: UUID?
    let surfaceId: UUID
}

enum RightSidebarRemoteApplyResult: Equatable, Sendable {
    case ok
    case state(RightSidebarRemoteState)
    case surface(RightSidebarRemoteSurface)
    case failure(String)
}

extension RightSidebarRemoteRequest {
    static func parse(tokens: [String]) -> Result<RightSidebarRemoteRequest, RightSidebarRemoteParseError> {
        var positional: [String] = []
        var target = RightSidebarRemoteTarget()
        var noFocus = false
        var paneId: UUID?
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            if token == "--no-focus" {
                noFocus = true
                index += 1
                continue
            }
            if token == "--pane" || token.hasPrefix("--pane=") {
                let rawValue: String
                if token == "--pane" {
                    guard index + 1 < tokens.count else {
                        return .failure(.init(message: String(localized: "rightSidebar.remote.error.optionRequiresID", defaultValue: "ERROR: \(token) requires an id")))
                    }
                    rawValue = tokens[index + 1]
                    index += 2
                } else {
                    rawValue = String(token.dropFirst("--pane=".count))
                    index += 1
                }
                guard let uuid = UUID(uuidString: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return .failure(.init(message: String(localized: "rightSidebar.remote.error.invalidPaneID", defaultValue: "ERROR: Invalid right sidebar --pane id '\(rawValue)'")))
                }
                paneId = uuid
                continue
            }
            if token == "--workspace" || token == "--tab" || token == "--window" {
                guard index + 1 < tokens.count else {
                    return .failure(.init(message: String(localized: "rightSidebar.remote.error.optionRequiresID", defaultValue: "ERROR: \(token) requires an id")))
                }
                let value = tokens[index + 1]
                if let error = parseTargetOption(name: String(token.dropFirst(2)), value: value, target: &target) {
                    return .failure(error)
                }
                index += 2
                continue
            }
            if token.hasPrefix("--workspace=") {
                let value = String(token.dropFirst("--workspace=".count))
                if let error = parseTargetOption(name: "workspace", value: value, target: &target) {
                    return .failure(error)
                }
                index += 1
                continue
            }
            if token.hasPrefix("--tab=") {
                let value = String(token.dropFirst("--tab=".count))
                if let error = parseTargetOption(name: "tab", value: value, target: &target) {
                    return .failure(error)
                }
                index += 1
                continue
            }
            if token.hasPrefix("--window=") {
                let value = String(token.dropFirst("--window=".count))
                if let error = parseTargetOption(name: "window", value: value, target: &target) {
                    return .failure(error)
                }
                index += 1
                continue
            }
            if token.hasPrefix("--") {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.unknownOption", defaultValue: "ERROR: Unknown right sidebar option '\(token)'")))
            }
            positional.append(token)
            index += 1
        }

        guard let action = positional.first?.lowercased() else {
            return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage", defaultValue: "ERROR: Usage: right_sidebar <toggle|show|hide|focus|set|mode|set-root|open-pane> [mode|path] [--workspace=<workspace-id>] [--window=<window-id>] [--pane=<pane-id>] [--no-focus]")))
        }

        if paneId != nil, action != "open-pane", action != "open_pane" {
            return .failure(.init(message: String(localized: "rightSidebar.remote.error.paneOnlyOpenPane", defaultValue: "ERROR: --pane is only valid with right_sidebar open-pane")))
        }

        switch action {
        case "toggle":
            guard positional.count == 1, !noFocus else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.toggle", defaultValue: "ERROR: Usage: right_sidebar toggle [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .toggle, target: target))
        case "show":
            guard positional.count == 1, !noFocus else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.show", defaultValue: "ERROR: Usage: right_sidebar show [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .show, target: target))
        case "hide":
            guard positional.count == 1, !noFocus else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.hide", defaultValue: "ERROR: Usage: right_sidebar hide [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .hide, target: target))
        case "focus":
            guard positional.count == 1, !noFocus else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.focus", defaultValue: "ERROR: Usage: right_sidebar focus [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .focus, target: target))
        case "mode", "state":
            guard positional.count == 1, !noFocus else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.mode", defaultValue: "ERROR: Usage: right_sidebar mode [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .getState, target: target))
        case "set-root":
            guard positional.count == 2, !noFocus else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.setRoot", defaultValue: "ERROR: Usage: right_sidebar set-root <path|auto> [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            let rawPath = positional[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPath.isEmpty else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.setRoot", defaultValue: "ERROR: Usage: right_sidebar set-root <path|auto> [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            let lowered = rawPath.lowercased()
            let clearsOverride = lowered == "auto" || lowered == "clear"
            return .success(.init(command: .setFilesRoot(clearsOverride ? nil : rawPath), target: target))
        case "open-pane", "open_pane":
            guard positional.count == 2 else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.openPane", defaultValue: "ERROR: Usage: right_sidebar open-pane <files|find|vault> [--pane=<pane-id>] [--no-focus] [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            let rawPaneMode = positional[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let paneMode = RightSidebarMode.from(cliArgument: rawPaneMode), paneMode.canOpenAsPane else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.unknownPaneMode", defaultValue: "ERROR: Right sidebar mode '\(positional[1])' cannot open as a pane")))
            }
            return .success(.init(command: .openPane(paneMode, paneId: paneId, focus: !noFocus), target: target))
        case "set":
            guard positional.count == 2 else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.set", defaultValue: "ERROR: Usage: right_sidebar set <files|find|vault|sessions|feed|dock> [--no-focus] [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            let rawMode = positional[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if let mode = RightSidebarMode.from(cliArgument: rawMode), mode != .customSidebar {
                return .success(.init(command: .setMode(mode, focus: !noFocus), target: target))
            }
            return .failure(.init(message: String(localized: "rightSidebar.remote.error.unknownMode", defaultValue: "ERROR: Unknown right sidebar mode '\(positional[1])'")))
        default:
            guard !noFocus else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.noFocusOnlySet", defaultValue: "ERROR: --no-focus is only valid with right_sidebar set")))
            }
            guard positional.count == 1 else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.unknownCommand", defaultValue: "ERROR: Unknown right sidebar command '\(action)'")))
            }
            if let mode = RightSidebarMode.from(cliArgument: action), mode != .customSidebar {
                return .success(.init(command: .setMode(mode, focus: true), target: target))
            }
            return .failure(.init(message: String(localized: "rightSidebar.remote.error.unknownCommand", defaultValue: "ERROR: Unknown right sidebar command '\(action)'")))
        }
    }

    private static func parseTargetOption(
        name: String,
        value: String,
        target: inout RightSidebarRemoteTarget
    ) -> RightSidebarRemoteParseError? {
        guard let uuid = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .init(message: String(localized: "rightSidebar.remote.error.invalidTargetID", defaultValue: "ERROR: Invalid right sidebar --\(name) id '\(value)'"))
        }
        switch name {
        case "window":
            target.windowId = uuid
        case "workspace", "tab":
            target.workspaceId = uuid
        default:
            return .init(message: String(localized: "rightSidebar.remote.error.unknownTargetOption", defaultValue: "ERROR: Unknown right sidebar target option '\(name)'"))
        }
        return nil
    }
}
