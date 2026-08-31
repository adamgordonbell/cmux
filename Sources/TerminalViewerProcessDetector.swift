import Darwin
import Foundation

/// Decides whether a terminal surface is running only read-only "viewer"
/// processes — a pager (`less`, `man`, `bat`, `tail -f`) or an editor pinned
/// into read-only view mode (`nvim -R` / `vim -R` / `view`). Closing such a
/// surface cannot lose work, so `TerminalPanel.needsConfirmClose()` skips the
/// "process is still running" confirmation for it. A plain `nvim`/`vim`
/// session (no `-R`) keeps the confirmation: it may hold unsaved edits.
///
/// The tty is queried fresh via `ps` on a cache miss — tty caches like
/// `Workspace.surfaceTTYNames` update asynchronously, and a stale answer here
/// would either nag or, worse, skip a confirmation that was owed. Verdicts are
/// memoized for a short TTL because `needsConfirmClose()` is also consulted by
/// session-snapshot persistence, which runs far more often than tabs close.
///
/// Kill switch: `defaults write <bundle-id> skipCloseConfirmForViewerProcesses -bool NO`.
enum TerminalViewerProcessDetector {

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "skipCloseConfirmForViewerProcesses") as? Bool ?? true
    }

    /// Read-only by construction, whatever their arguments.
    private static let pagerExecutables: Set<String> = [
        "less", "more", "most", "man", "bat", "tail", "watch"
    ]
    /// Viewers only when launched read-only (`-R`); `view` is vim's alias for it.
    private static let readOnlyFlagEditors: Set<String> = ["nvim", "vim"]
    /// Present in any terminal and carrying no closable work of their own.
    /// `ps` is listed because the sampler's own `ps` can observe itself;
    /// `sleep` because zsh prompt plugins park one on the controlling tty.
    private static let shellExecutables: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "tcsh", "ksh", "login", "ps", "sleep"
    ]
    /// Prompt-machinery daemons that share the tty, matched by prefix because
    /// `ps -o ucomm=` truncates ("gitstatusd-darwin-arm64" → "gitstatusd-darwi").
    private static let harmlessPrefixes: [String] = ["gitstatusd"]

    struct ProcessSample {
        let executableName: String
        let arguments: [String]
    }

    /// Pure decision, separated from the `ps` sampling for testability:
    /// viewer-only iff at least one non-shell process exists and every
    /// non-shell process is a viewer.
    static func isViewerOnly(_ samples: [ProcessSample]) -> Bool {
        let nonShell = samples.filter { sample in
            let name = sample.executableName.lowercased()
            if shellExecutables.contains(name) { return false }
            if harmlessPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
            return true
        }
        guard !nonShell.isEmpty else { return false }
        return nonShell.allSatisfy { sample in
            let name = sample.executableName.lowercased()
            if pagerExecutables.contains(name) { return true }
            if name == "view" { return true }
            if readOnlyFlagEditors.contains(name) {
                return sample.arguments.dropFirst().contains("-R")
            }
            return false
        }
    }

    private struct CacheEntry {
        let verdict: Bool
        let at: Date
    }
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: CacheEntry] = [:]
    private static let cacheTTL: TimeInterval = 3

    static func surfaceIsViewerOnly(ttyName: String?) -> Bool {
        guard isEnabled() else { return false }
        guard let ttyName else { return false }
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let short = trimmed.hasPrefix("/dev/") ? String(trimmed.dropFirst("/dev/".count)) : trimmed

        let now = Date()
        cacheLock.lock()
        if let hit = cache[short], now.timeIntervalSince(hit.at) < cacheTTL {
            cacheLock.unlock()
            return hit.verdict
        }
        cacheLock.unlock()

        let verdict = isViewerOnly(sampleProcesses(onTTY: short))

        cacheLock.lock()
        cache[short] = CacheEntry(verdict: verdict, at: now)
        cacheLock.unlock()
        return verdict
    }

    private static func sampleProcesses(onTTY tty: String) -> [ProcessSample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-t", tty, "-o", "pid=,ucomm="]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").compactMap { line -> ProcessSample? in
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
            let name = String(parts[1])
            // Full argv (for the -R check) via KERN_PROCARGS2; ucomm is the
            // fallback when the sysctl read is refused.
            let args = TerminalSSHSessionDetector.commandLineArguments(forPID: pid) ?? [name]
            return ProcessSample(executableName: name, arguments: args)
        }
    }
}
