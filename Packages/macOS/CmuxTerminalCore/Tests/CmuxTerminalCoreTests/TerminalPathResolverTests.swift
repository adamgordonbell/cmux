import Foundation
import Testing
import CmuxTerminalCore

private func existsIn(_ existingPaths: Set<String>) -> @Sendable (String) -> Bool {
    { path in existingPaths.contains((path as NSString).standardizingPath) }
}

@Suite struct TerminalPathTrailingPunctuationTests {
    @Test func trimsTrailingPeriodAfterMarkdownFile() {
        #expect(
            "~/ClaudeCode/feature-spec-template.md.".trimmingTrailingTerminalPunctuation()
                == "~/ClaudeCode/feature-spec-template.md"
        )
    }

    @Test func trimsTrailingCommaInList() {
        #expect(
            "/tmp/fixtures/first.txt,".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/first.txt"
        )
    }

    @Test func trimsTrailingCloseParenWhenNoBalancedOpenParen() {
        #expect(
            "/tmp/fixtures/notes.txt)".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/notes.txt"
        )
    }

    @Test func preservesBalancedParensInMiddleOfPath() {
        #expect(
            "/tmp/fixtures/report (draft)/notes.txt".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/report (draft)/notes.txt"
        )
    }

    @Test func stripsMultipleTrailingPunctuationCharacters() {
        #expect(
            "/tmp/fixtures/report (draft).md).,!?\"".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/report (draft).md"
        )
    }

    @Test func trimsTrailingClosingQuote() {
        #expect(
            "/tmp/fixtures/notes.txt\"".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/notes.txt"
        )
    }
}

@Suite struct TerminalQuicklookPathResolutionTests {
    @Test func fallsBackToStrippedPathWhenLiteralPathIsMissing() {
        let strippedPath = "/tmp/cmux-cmdclick-path.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([strippedPath])).resolveQuicklookPath(
                "\(strippedPath).",
                cwd: "/tmp"
            ) == strippedPath
        )
    }

    @Test func prefersLiteralPathThatReallyEndsWithDot() {
        let literalPath = "/tmp/cmux-cmdclick-literal-dot.md."
        let strippedPath = "/tmp/cmux-cmdclick-literal-dot.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([literalPath, strippedPath])).resolveQuicklookPath(
                literalPath,
                cwd: "/tmp"
            ) == literalPath
        )
    }

    @Test func prefersLiteralPathThatReallyEndsWithParen() {
        let literalPath = "/tmp/cmux-cmdclick-literal-paren)"
        let strippedPath = "/tmp/cmux-cmdclick-literal-paren"
        #expect(
            TerminalPathResolver(fileExists: existsIn([literalPath, strippedPath])).resolveQuicklookPath(
                literalPath,
                cwd: "/tmp"
            ) == literalPath
        )
    }

    @Test func resolvesRelativeMarkdownPathWithTrailingDot() {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/docs/specs/2026-05-22-test.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "docs/specs/2026-05-22-test.md.",
                cwd: cwd
            ) == existingFile
        )
    }

    @Test func resolvesRelativePathWithTrailingComma() {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/src/main.swift"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "src/main.swift,",
                cwd: cwd
            ) == existingFile
        )
    }

    @Test func returnsNilForRelativePathThatDoesNotExist() {
        #expect(
            TerminalPathResolver(fileExists: existsIn([])).resolveQuicklookPath(
                "docs/nonexistent.md.",
                cwd: "/Users/dev/project"
            ) == nil
        )
    }

    @Test func relativeCandidateWithoutCwdIsSkipped() {
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveQuicklookPath(
                "src/main.swift",
                cwd: nil
            ) == nil
        )
    }

    @Test func unquotesShellQuotedToken() {
        let existingFile = "/tmp/cmux quicklook spaced.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "\"\(existingFile)\"",
                cwd: "/tmp"
            ) == existingFile
        )
    }

    @Test func unescapesBackslashEscapedSpaces() {
        let existingFile = "/tmp/cmux quicklook escaped.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "/tmp/cmux\\ quicklook\\ escaped.md",
                cwd: "/tmp"
            ) == existingFile
        )
    }
}

@Suite struct TerminalOpenURLFilePathTests {
    @Test func resolvesAbsoluteMarkdownPathWithTrailingDot() {
        let existingFile = "/Users/dev/project/skills/marketing/data/lawrencecchen-tweets.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFilePath(
                "\(existingFile).",
                cwd: "/Users/dev/project"
            ) == existingFile
        )
    }

    @Test func resolvesQuotedAbsoluteMarkdownPathWithTrailingDot() {
        let existingFile = "/Users/dev/project/skills/marketing/data/lawrencecchen-tweets.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFilePath(
                "\"\(existingFile).\"",
                cwd: "/Users/dev/project"
            ) == existingFile
        )
    }

    @Test func textWithURLSchemeIsNeverTreatedAsFilePath() {
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveOpenURLFilePath(
                "file:///tmp/test.md",
                cwd: "/tmp"
            ) == nil
        )
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveOpenURLFilePath(
                "mailto:test@example.com",
                cwd: "/tmp"
            ) == nil
        )
    }

    @Test func schemelessRelativeAndAbsoluteTextStaysEligible() {
        let relative = "/Users/dev/project/docs/specs/2026-05-22-test.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([relative])).resolveOpenURLFilePath(
                "docs/specs/2026-05-22-test.md.",
                cwd: "/Users/dev/project"
            ) == relative
        )
    }
}

@Suite struct TerminalVisibleLineResolutionTests {
    @Test func visibleLinesKeepsTrailingRowsOnly() {
        let text = "one\ntwo\nthree\nfour"
        #expect(text.visibleLines(rows: 2) == ["three", "four"])
        #expect(text.visibleLines(rows: 10) == ["one", "two", "three", "four"])
    }

    @Test func visibleLinesPreservesEmptyLines() {
        #expect("a\n\nb".visibleLines(rows: 3) == ["a", "", "b"])
    }

    @Test func resolvesRawSegmentUnderColumn() throws {
        let existingFile = "/tmp/cmux-visible-line.md"
        let line = "open /tmp/cmux-visible-line.md now"
        let resolution = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveVisibleLinePath(
                line,
                column: 8,
                cwd: "/tmp"
            )
        )
        #expect(resolution.path == existingFile)
        #expect(resolution.rawToken == "/tmp/cmux-visible-line.md")
    }

    @Test func resolvesShellEscapedTokenSpanningSpaces() throws {
        let existingFile = "/tmp/cmux visible escaped.md"
        let line = "cat /tmp/cmux\\ visible\\ escaped.md"
        let resolution = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveVisibleLinePath(
                line,
                column: 6,
                cwd: "/tmp"
            )
        )
        #expect(resolution.path == existingFile)
    }

    @Test func returnsNilWhenColumnSitsOnHardDelimiter() {
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveVisibleLinePath(
                "a\tb",
                column: 1,
                cwd: "/tmp"
            ) == nil
        )
    }
}

@Suite struct TerminalRepositoryRootResolutionTests {
    /// Agent output spells paths from the repository root while the shell can
    /// be anywhere inside it, so the cwd join alone misses.
    @Test func resolvesRepoRelativePathFromNestedCwd() {
        let resolver = TerminalPathResolver(fileExists: existsIn([
            "/repo/.git",
            "/repo/projects/notion-interview/prep.md",
        ]))
        #expect(
            resolver.resolveQuicklookPath(
                "projects/notion-interview/prep.md",
                cwd: "/repo/scripts/nested"
            ) == "/repo/projects/notion-interview/prep.md"
        )
    }

    @Test func prefersCwdMatchOverRepositoryRootMatch() {
        let resolver = TerminalPathResolver(fileExists: existsIn([
            "/repo/.git",
            "/repo/docs/notes.md",
            "/repo/scripts/docs/notes.md",
        ]))
        #expect(
            resolver.resolveQuicklookPath("docs/notes.md", cwd: "/repo/scripts")
                == "/repo/scripts/docs/notes.md"
        )
    }

    @Test func stopsAtNearestRepositoryRoot() {
        // An inner repo must not have its lookups answered by the outer one.
        let resolver = TerminalPathResolver(fileExists: existsIn([
            "/outer/.git",
            "/outer/inner/.git",
            "/outer/shared/file.md",
        ]))
        #expect(
            resolver.resolveQuicklookPath("shared/file.md", cwd: "/outer/inner/deep") == nil
        )
    }

    @Test func returnsNilOutsideAnyRepository() {
        let resolver = TerminalPathResolver(fileExists: existsIn([
            "/elsewhere/projects/prep.md",
        ]))
        #expect(
            resolver.resolveQuicklookPath("projects/prep.md", cwd: "/tmp/scratch") == nil
        )
    }

    @Test func absolutePathsStillResolveWithoutCwd() {
        let resolver = TerminalPathResolver(fileExists: existsIn(["/tmp/notes.md"]))
        #expect(resolver.resolveQuicklookPath("/tmp/notes.md", cwd: nil) == "/tmp/notes.md")
    }

    /// A path spelled against an intermediate directory — neither the cwd nor
    /// the repository root — still resolves via the ancestor walk.
    @Test func resolvesAgainstIntermediateAncestor() {
        let resolver = TerminalPathResolver(fileExists: existsIn([
            "/repo/.git",
            "/repo/projects/alpha/spike/PROMPT.md",
        ]))
        #expect(
            resolver.resolveQuicklookPath("spike/PROMPT.md", cwd: "/repo/projects/alpha/deep/deeper")
                == "/repo/projects/alpha/spike/PROMPT.md"
        )
    }
}

/// Records whether the search capability was invoked, from inside a `@Sendable`
/// closure.
private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func mark() {
        lock.lock(); defer { lock.unlock() }
        fired = true
    }

    var wasCalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }
}

@Suite struct TerminalPathSearchResolutionTests {
    private func resolver(
        existing: Set<String> = [],
        matches: [String] = []
    ) -> TerminalPathResolver {
        TerminalPathResolver(
            fileExists: existsIn(existing),
            searchSuffix: { _, _ in matches }
        )
    }

    @Test func exactMatchWinsAndSkipsSearchEntirely() {
        let flag = CallFlag()
        let resolver = TerminalPathResolver(
            fileExists: existsIn(["/repo/.git", "/repo/docs/notes.md"]),
            searchSuffix: { _, _ in flag.mark(); return ["/elsewhere/docs/notes.md"] }
        )
        #expect(resolver.resolveWithSearch("docs/notes.md", cwd: "/repo") == .single("/repo/docs/notes.md"))
        #expect(flag.wasCalled == false)
    }

    /// The reported case: a path spelled relative to a project directory the
    /// terminal knows nothing about.
    @Test func findsProjectRelativePathBySuffix() {
        let resolved = resolver(
            existing: ["/repo/.git"],
            matches: ["/repo/projects/sprint/spike/brief/narrator/PROMPT.md"]
        ).resolveWithSearch("spike/brief/narrator/PROMPT.md", cwd: "/repo")
        #expect(resolved == .single("/repo/projects/sprint/spike/brief/narrator/PROMPT.md"))
    }

    @Test func reportsAmbiguityShallowestFirst() {
        let resolved = resolver(
            existing: ["/repo/.git"],
            matches: ["/repo/a/b/c/docs/notes.md", "/repo/x/docs/notes.md"]
        ).resolveWithSearch("docs/notes.md", cwd: "/repo")
        #expect(resolved == .ambiguous(["/repo/x/docs/notes.md", "/repo/a/b/c/docs/notes.md"]))
    }

    @Test func bareWordIsNeverSearched() {
        let flag = CallFlag()
        let resolver = TerminalPathResolver(
            fileExists: { _ in false },
            searchSuffix: { _, _ in flag.mark(); return [] }
        )
        #expect(resolver.resolveWithSearch("PROMPT", cwd: "/repo") == .none)
        #expect(flag.wasCalled == false)
    }

    @Test func absoluteTokenIsNeverSearched() {
        let flag = CallFlag()
        let resolver = TerminalPathResolver(
            fileExists: { _ in false },
            searchSuffix: { _, _ in flag.mark(); return [] }
        )
        #expect(resolver.resolveWithSearch("/gone/missing.md", cwd: "/repo") == .none)
        #expect(flag.wasCalled == false)
    }

    @Test func reportsNoneWhenSearchFindsNothing() {
        #expect(resolver(existing: ["/repo/.git"]).resolveWithSearch("a/b.md", cwd: "/repo") == .none)
    }

    @Test func deduplicatesMatchesAcrossRoots() {
        let resolved = resolver(
            existing: ["/repo/.git"],
            matches: ["/repo/docs/notes.md"]
        ).resolveWithSearch("docs/notes.md", cwd: "/repo", searchRoots: ["/other"])
        #expect(resolved == .single("/repo/docs/notes.md"))
    }
}
