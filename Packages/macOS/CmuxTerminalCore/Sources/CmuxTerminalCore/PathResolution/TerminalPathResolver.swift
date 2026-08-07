public import Foundation

/// Resolves file-system paths out of raw terminal text.
///
/// This is the shared path heuristics layer behind cmd-click QuickLook,
/// "open file at cursor", and terminal link opening. Candidate spellings come
/// from the pure `String` transforms in this domain (shell-token unquoting
/// and unescaping, trailing-punctuation trimming, visible-line
/// tokenization); the resolver expands them for `~`, resolves relative
/// candidates against the surface cwd, standardizes, and probes in order.
///
/// The resolver is an instantiated value because resolution is pure only up
/// to the file system: every resolve probes candidates for existence, so the
/// file-existence capability is injected at init. Production uses the real
/// file system; tests inject a fake probe. This mirrors
/// ``TerminalLinkRouter``'s injected `BrowserHostNormalizing` seam.
public struct TerminalPathResolver: Sendable {
    private let fileExists: @Sendable (String) -> Bool
    private let searchSuffix: @Sendable (String, String) -> [String]

    /// Creates a resolver that probes candidate paths through `fileExists`.
    ///
    /// - Parameters:
    ///   - fileExists: The file-existence capability; defaults to the real
    ///     file system.
    ///   - searchSuffix: Finds files under a root whose path ends with a given
    ///     suffix, for ``resolveWithSearch(_:cwd:searchRoots:)``. Defaults to
    ///     ``TerminalPathSuffixSearch/live``; tests inject a fake so no
    ///     subprocess runs.
    public init(
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        searchSuffix: @escaping @Sendable (String, String) -> [String] = TerminalPathSuffixSearch.live
    ) {
        self.fileExists = fileExists
        self.searchSuffix = searchSuffix
    }

    /// Resolves raw terminal text to an existing file path for QuickLook.
    ///
    /// Candidates are derived from the raw text (as-is, shell-unescaped,
    /// shell-unquoted, and trailing-punctuation-trimmed variants), expanded
    /// for `~`, resolved against `cwd` when relative, standardized, and probed
    /// in order. The first existing path wins.
    ///
    /// - Parameters:
    ///   - rawText: The raw text under the cursor or selection.
    ///   - cwd: The surface's working directory used for relative candidates.
    /// - Returns: The first existing standardized path, or `nil`.
    public func resolveQuicklookPath(_ rawText: String, cwd: String?) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokens = trimmed.pathResolutionCandidates()
        var seenPaths: Set<String> = []

        // Bases are tried in order and the cwd goes first, so a token that
        // resolves against the surface's own directory always wins.
        for base in resolutionBases(cwd: cwd) {
            for token in tokens {
                let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedToken.isEmpty else { continue }

                let expandedToken = (normalizedToken as NSString).expandingTildeInPath
                let candidatePath: String
                if expandedToken.hasPrefix("/") {
                    candidatePath = expandedToken
                } else {
                    guard let base, !base.isEmpty else { continue }
                    candidatePath = (base as NSString).appendingPathComponent(expandedToken)
                }

                let standardizedPath = (candidatePath as NSString).standardizingPath
                guard seenPaths.insert(standardizedPath).inserted else { continue }
                if fileExists(standardizedPath) {
                    return standardizedPath
                }
            }
        }

        return nil
    }

    /// Directories a relative candidate is resolved against, most specific first.
    ///
    /// The surface cwd alone is not enough for terminal text that spells paths
    /// from a repository root — the common case for agent output, which quotes
    /// `projects/foo/notes.md` while the shell sits several directories deep.
    /// Ghostty only links tokens containing a slash, so these are recognisably
    /// paths; they just need a second base to be found under.
    private func resolutionBases(cwd: String?) -> [String?] {
        guard let cwd, !cwd.isEmpty else { return [nil] }

        // Walk cwd -> repository root, so a path spelled from an intermediate
        // directory (a project dir inside a larger repo, say) is found without
        // needing to know which level it was written against.
        let stopAt = repositoryRoot(containing: cwd)
        var bases: [String?] = []
        var current = (cwd as NSString).standardizingPath
        while true {
            bases.append(current)
            if current == stopAt || current == "/" || current.isEmpty { break }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
            if stopAt == nil { break }
        }
        return bases
    }

    /// Whether text is a schemeless, slash-bearing token — the shape Ghostty
    /// links as a relative path.
    ///
    /// Callers use this to tell "a path that does not exist" apart from "not a
    /// path at all", so a failed resolution can be swallowed rather than handed
    /// to a URL opener that would act on nonsense.
    public static func looksLikeRelativePath(_ rawText: String) -> Bool {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("/"), !trimmed.hasPrefix("/") else { return false }
        return URL(string: trimmed)?.scheme == nil
    }

    /// The local file-system path a `file://` URL names, if it names one.
    ///
    /// Agents (Claude Code among them) emit paths as OSC 8 hyperlinks with an
    /// absolute `file://` target, so the text the user clicks looks like a
    /// relative path but arrives here already resolved and scheme-bearing. Every
    /// other resolution entry point rejects schemes — correctly, since `https://`
    /// is not a path — which sent these straight to the system opener and out to
    /// whatever app owns the extension, instead of cmux's own viewer.
    ///
    /// Only host-less (or explicitly local) URLs qualify: `file://someserver/x`
    /// names a remote resource, not a path on this machine.
    public static func localFilePath(fromFileURL rawText: String) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.isFileURL else { return nil }
        let host = url.host ?? ""
        guard host.isEmpty || host == "localhost" else { return nil }
        let path = url.path
        return path.isEmpty ? nil : path
    }

    /// Outcome of resolving a token that no base could account for.
    public enum SearchResolution: Equatable, Sendable {
        case none
        case single(String)
        /// More than one file ends with the token; the caller disambiguates.
        case ambiguous([String])
    }

    /// Resolves a token by searching for files whose path *ends* with it.
    ///
    /// Exact bases are tried first and win outright. The search only runs when
    /// they all miss, because terminal text routinely spells a path relative to
    /// something the terminal has no knowledge of — a project directory the
    /// author had in mind, for instance. Matching on the path suffix finds the
    /// file by identity rather than guessing which directory was meant.
    ///
    /// Suffix matching, not fuzzy matching: the token is already a path
    /// fragment, so anchoring it is both cheaper and far more precise than
    /// scoring. Ambiguity is reported rather than guessed at.
    public func resolveWithSearch(
        _ rawText: String,
        cwd: String?,
        searchRoots: [String] = []
    ) -> SearchResolution {
        if let exact = resolveQuicklookPath(rawText, cwd: cwd) {
            return .single(exact)
        }

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        // Only path-shaped tokens are worth searching for. A bare word would
        // match far too much, and Ghostty never links one anyway.
        guard trimmed.contains("/"), !trimmed.hasPrefix("/") else { return .none }

        var roots = searchRoots
        if let cwd, !cwd.isEmpty {
            roots.append(repositoryRoot(containing: cwd) ?? cwd)
        }

        var matches: [String] = []
        var seen: Set<String> = []
        for root in roots where !root.isEmpty {
            for match in searchSuffix(root, trimmed) {
                let standardized = (match as NSString).standardizingPath
                guard seen.insert(standardized).inserted else { continue }
                matches.append(standardized)
            }
        }

        switch matches.count {
        case 0: return .none
        case 1: return .single(matches[0])
        default:
            // Shallowest first: the least-nested match is the likeliest intent
            // and leads a disambiguation menu sensibly.
            return .ambiguous(
                matches.sorted {
                    let lhs = $0.components(separatedBy: "/").count
                    let rhs = $1.components(separatedBy: "/").count
                    return lhs == rhs ? $0 < $1 : lhs < rhs
                }
            )
        }
    }

    /// Nearest ancestor of `directory` holding a `.git` entry, if any.
    ///
    /// Probed through the injected `fileExists` rather than by shelling out to
    /// git, so this stays testable and adds no subprocess to a click.
    private func repositoryRoot(containing directory: String) -> String? {
        var current = (directory as NSString).standardizingPath
        guard current.hasPrefix("/") else { return nil }

        while current != "/" && !current.isEmpty {
            if fileExists((current as NSString).appendingPathComponent(".git")) {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current else { break }
            current = parent
        }
        return nil
    }

    /// Resolves the path token under a column of a visible terminal line.
    ///
    /// Tries the raw whitespace-delimited segment around the column first,
    /// then the shell-escape-aware token, and resolves each through
    /// ``resolveQuicklookPath(_:cwd:)``.
    ///
    /// - Parameters:
    ///   - line: The visible line text.
    ///   - column: The zero-based column under the cursor.
    ///   - cwd: The surface's working directory.
    /// - Returns: The raw token plus its resolved path, or `nil`.
    public func resolveVisibleLinePath(
        _ line: String,
        column: Int,
        cwd: String
    ) -> (rawToken: String, path: String)? {
        for rawToken in line.pathTokenCandidates(containingColumn: column) {
            if let resolvedPath = resolveQuicklookPath(rawToken, cwd: cwd) {
                return (rawToken, resolvedPath)
            }
        }
        return nil
    }

    /// Resolves an open-URL request payload to an existing file path.
    ///
    /// Text that parses as a URL with a scheme is never treated as a file
    /// path; everything else goes through ``resolveQuicklookPath(_:cwd:)``.
    ///
    /// - Parameters:
    ///   - rawText: The raw open-URL text from the runtime.
    ///   - cwd: The surface's working directory.
    /// - Returns: The first existing standardized path, or `nil`.
    public func resolveOpenURLFilePath(_ rawText: String, cwd: String?) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard URL(string: trimmed)?.scheme == nil else { return nil }
        return resolveQuicklookPath(trimmed, cwd: cwd)
    }
}
