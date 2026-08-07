import Foundation

/// Finds files under a root whose path ends with a given suffix.
///
/// Backs ``TerminalPathResolver/resolveWithSearch(_:cwd:searchRoots:)``, and
/// runs only after every exact base has missed — never on hover, and never on
/// a click that resolved normally.
///
/// ## Why ignore-awareness decides the strategy
///
/// Measured on a real repo tree (2026-08-06): 3,982 files once
/// `.gitignore` is honored, 431,644 when it is not — 8.5s versus 10ms for the
/// same traversal. The gap is not `.git` or `node_modules`; it is one ignored
/// project directory holding 258,340 files, whose name no hand-written prune
/// list would ever contain. That rules out a generic pruned walk as the primary
/// strategy: only the repository's own ignore rules know what is noise.
///
/// So, in order:
///
/// 1. `fd` — honors `.gitignore`, works outside repositories, fastest measured.
/// 2. `git ls-files` — same ignore rules without the dependency, but blind
///    outside a repository. `--others --exclude-standard` matters: without it
///    untracked files are invisible, which is exactly the newest work.
/// 3. A depth-capped walk — the only option for a non-repository directory with
///    no `fd`. Bounded because nothing prunes it.
public enum TerminalPathSuffixSearch {
    /// Depth limit for the unpruned fallback walk. Nothing constrains that
    /// traversal but this number, so it stays small.
    private static let fallbackWalkDepthLimit = 6
    private static let matchLimit = 32

    public static let live: @Sendable (String, String) -> [String] = { root, suffix in
        search(root: root, suffix: suffix)
    }

    static func search(root: String, suffix: String) -> [String] {
        let normalizedSuffix = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
        guard !normalizedSuffix.isEmpty else { return [] }

        if let fd = executablePath(for: "fd"),
           let matches = runSearch(
               executable: fd,
               // --absolute-path so results need no rejoining; --full-path lets
               // the glob anchor on the trailing segments rather than the name.
               arguments: ["--absolute-path", "--full-path", "--type", "f", "--glob", "**/\(normalizedSuffix)"],
               root: root
           ) {
            return Array(matches.prefix(matchLimit))
        }

        if let git = executablePath(for: "git"), isRepository(root: root) {
            if let listed = runSearch(
                executable: git,
                arguments: ["ls-files", "--cached", "--others", "--exclude-standard"],
                root: root
            ) {
                let matches = listed
                    .filter { $0 == normalizedSuffix || $0.hasSuffix("/" + normalizedSuffix) }
                    .map { (root as NSString).appendingPathComponent($0) }
                return Array(matches.prefix(matchLimit))
            }
        }

        return Array(depthCappedWalk(root: root, suffix: normalizedSuffix).prefix(matchLimit))
    }

    private static func isRepository(root: String) -> Bool {
        FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git"))
    }

    private static func executablePath(for name: String) -> String? {
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func runSearch(
        executable: String,
        arguments: [String],
        root: String
    ) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func depthCappedWalk(root: String, suffix: String) -> [String] {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var matches: [String] = []
        for case let url as URL in enumerator {
            if enumerator.level > fallbackWalkDepthLimit {
                enumerator.skipDescendants()
                continue
            }
            let path = url.path
            if path == suffix || path.hasSuffix("/" + suffix) {
                matches.append(path)
                if matches.count >= matchLimit { break }
            }
        }
        return matches
    }
}
