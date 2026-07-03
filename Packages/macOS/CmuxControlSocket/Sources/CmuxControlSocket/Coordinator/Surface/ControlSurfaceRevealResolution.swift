public import Foundation

/// The outcome of `surface.reveal`.
///
/// Reveal selects the surface's tab within its pane WITHOUT moving keyboard
/// focus — for preview tooling (mdtab) that must show a tab while the user
/// keeps typing wherever they are.
public enum ControlSurfaceRevealResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable`).
    case tabManagerUnavailable
    /// No surface resolved from routing/params.
    case surfaceNotFound(UUID?)
    /// The tab was selected in its pane; keyboard focus untouched.
    case revealed(workspaceID: UUID, surfaceID: UUID)
}
