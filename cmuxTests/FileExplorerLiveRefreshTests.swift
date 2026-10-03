import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Fork: in-place re-listing keeps expanded subtrees instead of rebuilding the tree.
private final class ListingFileExplorerProvider: FileExplorerProvider {
    var homePath = "/home/user"
    var isAvailable = true
    var listings: [String: [FileExplorerEntry]] = [:]
    private(set) var listCallPaths: [String] = []

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        listCallPaths.append(path)
        return listings[path] ?? []
    }
}

@MainActor
@Suite(.serialized)
struct FileExplorerLiveRefreshTests {
    private static let root = "/p"

    private func entry(_ name: String, in dir: String = root, directory: Bool = false) -> FileExplorerEntry {
        FileExplorerEntry(name: name, path: dir + "/" + name, isDirectory: directory)
    }

    private func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for: \(description)")
    }

    /// Root with an expanded `src` holding `a.swift`.
    private func makeLoadedStore() async throws -> (FileExplorerStore, ListingFileExplorerProvider) {
        let provider = ListingFileExplorerProvider()
        provider.listings[Self.root] = [entry("src", directory: true), entry("README.md")]
        provider.listings["/p/src"] = [entry("a.swift", in: "/p/src")]
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath(Self.root)
        try await waitFor("root loaded") { store.rootNodes.count == 2 }
        let src = try #require(store.rootNodes.first)
        store.expand(node: src)
        try await waitFor("src loaded") { src.children?.count == 1 }
        return (store, provider)
    }

    @Test
    func testNewFileInExpandedFolderAppearsWithoutRebuildingTree() async throws {
        let (store, provider) = try await makeLoadedStore()
        let src = try #require(store.rootNodes.first)
        let a = try #require(src.children?.first)
        provider.listings["/p/src"] = [entry("a.swift", in: "/p/src"), entry("b.swift", in: "/p/src")]

        store.refreshDirectory(at: "/p/src")
        try await waitFor("b.swift listed") { src.children?.count == 2 }

        #expect(store.rootNodes.first === src)
        #expect(src.children?.first === a)
        #expect(store.expandedPaths.contains("/p/src"))
    }

    @Test
    func testRootRelistingKeepsExpandedFolderAndDropsRemovedFile() async throws {
        let (store, provider) = try await makeLoadedStore()
        let src = try #require(store.rootNodes.first)
        let revision = store.contentRevision
        provider.listings[Self.root] = [entry("src", directory: true), entry("new.txt")]

        store.refreshDirectory(at: Self.root)
        try await waitFor("root relisted") { store.contentRevision != revision }

        #expect(store.rootNodes.map(\.name) == ["src", "new.txt"])
        #expect(store.rootNodes.first === src)
        #expect(src.children?.count == 1)
    }

    @Test
    func testUnchangedListingLeavesContentRevisionAlone() async throws {
        let (store, provider) = try await makeLoadedStore()
        let revision = store.contentRevision
        let calls = provider.listCallPaths.count

        store.refreshDirectory(at: "/p/src")
        try await waitFor("src relisted") { provider.listCallPaths.count > calls }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.contentRevision == revision)
    }

    @Test
    func testNeverLoadedFolderIsNotListed() async throws {
        let provider = ListingFileExplorerProvider()
        provider.listings[Self.root] = [entry("lib", directory: true)]
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath(Self.root)
        try await waitFor("root loaded") { store.rootNodes.count == 1 }

        store.refreshDirectory(at: "/p/lib")
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(!provider.listCallPaths.contains("/p/lib"))
    }

    @Test
    func testReportedPathsMapBackIntoTheRootSpelling() {
        let map = { FileExplorerStore.mapReportedPath($0, root: "/tmp/x", canonicalRoot: "/private/tmp/x") }
        #expect(map("/private/tmp/x/a/b.txt") == "/tmp/x/a/b.txt")
        #expect(map("/tmp/x/c.txt") == "/tmp/x/c.txt")
        #expect(map("/private/tmp/x") == "/tmp/x")
        #expect(map("/private/tmp/xy/c.txt") == nil)
        #expect(map("/elsewhere/c.txt") == nil)
    }
}
