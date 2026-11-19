import Foundation
import XCTest
@testable import PSCore

private let RS = "\u{1E}"
private let FS = "\u{1F}"

private func commit(_ hash: String, _ parents: [String], _ subject: String = "") -> GitCommit {
    GitCommit(hash: hash, parents: parents, authorName: "A", authorEmail: "a@b.c", timestamp: 0, subject: subject, body: "")
}

final class GitParserTests: XCTestCase {
    func testLogParsing() {
        let output = "aaa" + FS + "bbb ccc" + FS + "Alice" + FS + "a@b.c" + FS + "1700000000" + FS + "subject" + FS + "body line" + RS + "\n"
            + "bbb" + FS + "ccc" + FS + "Bob" + FS + "b@c.d" + FS + "1699999999" + FS + "no body" + FS + RS + "\n"
        let commits = GitParser.log(output)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].hash, "aaa")
        XCTAssertEqual(commits[0].parents, ["bbb", "ccc"])
        XCTAssertEqual(commits[0].authorName, "Alice")
        XCTAssertEqual(commits[0].timestamp, 1_700_000_000)
        XCTAssertEqual(commits[0].subject, "subject")
        XCTAssertEqual(commits[0].body, "body line")
        XCTAssertEqual(commits[1].parents, ["ccc"])
        XCTAssertEqual(commits[1].body, "")
        XCTAssertEqual(commits[0].shortHash, "aaa")
    }

    func testLogParsingWithNewlinesInBody() {
        let output = "aaa" + FS + "" + FS + "A" + FS + "a@b.c" + FS + "1" + FS + "s" + FS + "line1\nline2\n" + RS + "\n"
        let commits = GitParser.log(output)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].body, "line1\nline2")
        XCTAssertEqual(commits[0].message, "s\n\nline1\nline2")
    }

    func testRefsParsing() {
        let output = "refs/heads/main" + FS + "aaa" + FS + "aaa" + RS + "\n"
            + "refs/remotes/origin/main" + FS + "bbb" + FS + "bbb" + RS + "\n"
            + "refs/tags/v1.0" + FS + "ccc" + FS + "ddd" + RS + "\n" // annotated tag: peeled = ccc
        let refs = GitParser.refs(output)
        XCTAssertEqual(refs, [
            GitRef(name: "main", kind: .localBranch, commit: "aaa"),
            GitRef(name: "origin/main", kind: .remoteBranch, commit: "bbb"),
            GitRef(name: "v1.0", kind: .tag, commit: "ccc"),
        ])
    }

    func testNameStatusParsing() {
        let output = "M\0a.txt\0A\0new.swift\0R100\0old.txt\0new.txt\0D\0gone.md\0"
        let parsed = GitParser.nameStatus(output)
        XCTAssertEqual(parsed.count, 4)
        XCTAssertEqual(parsed[0].status, "M")
        XCTAssertEqual(parsed[0].path, "a.txt")
        XCTAssertNil(parsed[0].oldPath)
        XCTAssertEqual(parsed[2].status, "R100")
        XCTAssertEqual(parsed[2].oldPath, "old.txt")
        XCTAssertEqual(parsed[2].path, "new.txt")
        XCTAssertEqual(GitParser.fileStatus("R100"), .renamed)
        XCTAssertEqual(GitParser.fileStatus("A"), .added)
        XCTAssertEqual(GitParser.fileStatus("D"), .deleted)
        XCTAssertEqual(GitParser.fileStatus("M"), .modified)
    }

    func testNumstatParsing() {
        let normal = "5\t1\ta.txt\0-\t-\tbin.dat\0"
        let parsed = GitParser.numstat(normal)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].added, 5)
        XCTAssertEqual(parsed[0].deleted, 1)
        XCTAssertEqual(parsed[0].path, "a.txt")
        XCTAssertNil(parsed[1].added)
        XCTAssertEqual(parsed[1].path, "bin.dat")

        let rename = "0\t0\0old.txt\0new.txt\0"
        let parsedRename = GitParser.numstat(rename)
        XCTAssertEqual(parsedRename.count, 1)
        XCTAssertEqual(parsedRename[0].oldPath, "old.txt")
        XCTAssertEqual(parsedRename[0].path, "new.txt")
    }
}

final class GitGraphLayoutTests: XCTestCase {
    private func lanes(of commits: [GitCommit], graph: GitGraph) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: zip(commits.map(\.hash), graph.nodes.map(\.lane)))
    }

    func testLinearHistory() {
        let commits = [commit("C", ["B"]), commit("B", ["A"]), commit("A", [])]
        let graph = GitGraphLayout.layout(commits)
        XCTAssertEqual(graph.nodes.map(\.lane), [0, 0, 0])
        XCTAssertEqual(graph.edges.count, 2)
        XCTAssertTrue(graph.edges.allSatisfy { $0.fromLane == 0 && $0.toLane == 0 })
        XCTAssertEqual(graph.laneCount, 1)
        XCTAssertTrue(graph.rows.allSatisfy { $0.outgoing.isEmpty && $0.incoming.isEmpty })
    }

    func testDivergingBranches() {
        // main: A-B, feature: A-C; topo order B, C, A
        let commits = [commit("B", ["A"]), commit("C", ["A"]), commit("A", [])]
        let graph = GitGraphLayout.layout(commits)
        let lanes = self.lanes(of: commits, graph: graph)
        XCTAssertEqual(lanes["B"], 0)
        XCTAssertEqual(lanes["C"], 1)
        XCTAssertEqual(lanes["A"], 0)
        // C's edge keeps its own lane; the curve into A is drawn at A's row.
        let cEdge = graph.edges.first { commits[$0.from].hash == "C" }!
        XCTAssertEqual(cEdge.fromLane, 1)
        XCTAssertEqual(cEdge.toLane, 1)
        XCTAssertEqual(graph.rows[2].incoming.map(\.lane), [1])
    }

    func testMerge() {
        // M has parents B (main) and C (feature); both have parent A.
        let commits = [commit("M", ["B", "C"]), commit("B", ["A"]), commit("C", ["A"]), commit("A", [])]
        let graph = GitGraphLayout.layout(commits)
        let lanes = self.lanes(of: commits, graph: graph)
        XCTAssertEqual([lanes["M"], lanes["B"], lanes["A"]], [0, 0, 0])
        XCTAssertEqual(lanes["C"], 1)
        let mergeEdges = graph.edges.filter { commits[$0.from].hash == "M" }
        XCTAssertEqual(mergeEdges.map(\.toLane).sorted(), [0, 1])
        // The merge edge into C curves out of M's row.
        XCTAssertEqual(graph.rows[0].outgoing.map(\.toLane), [1])
    }

    func testOctopusMerge() {
        let commits = [
            commit("M", ["B", "C", "D"]),
            commit("B", ["A"]), commit("C", ["A"]), commit("D", ["A"]),
            commit("A", []),
        ]
        let graph = GitGraphLayout.layout(commits)
        let lanes = self.lanes(of: commits, graph: graph)
        XCTAssertEqual(lanes["M"], 0)
        XCTAssertEqual([lanes["B"], lanes["C"], lanes["D"]].sorted(), [0, 1, 2])
        XCTAssertEqual(lanes["A"], 0)
        let mergeEdges = graph.edges.filter { commits[$0.from].hash == "M" }
        XCTAssertEqual(mergeEdges.map(\.toLane).sorted(), [0, 1, 2])
    }

    func testParallelBranchesGetDistinctColors() {
        let commits = [commit("X", ["A"]), commit("Y", ["A"]), commit("A", [])]
        let graph = GitGraphLayout.layout(commits)
        let colors = Set(graph.nodes.map(\.colorIndex))
        XCTAssertEqual(colors.count, 2)
        XCTAssertNotEqual(graph.nodes[0].colorIndex, graph.nodes[1].colorIndex)
        XCTAssertEqual(graph.nodes[0].colorIndex, 0) // first lane is always colour 0
    }

    func testLaneReuseAfterBranchEnds() {
        // D -> M, M merges B and C, all down to A; realistic topo order.
        let commits = [
            commit("D", ["M"]),
            commit("M", ["B", "C"]),
            commit("B", ["A"]),
            commit("C", ["A"]),
            commit("A", []),
        ]
        let graph = GitGraphLayout.layout(commits)
        let lanes = self.lanes(of: commits, graph: graph)
        XCTAssertEqual([lanes["D"], lanes["M"], lanes["B"], lanes["A"]], [0, 0, 0, 0])
        XCTAssertEqual(lanes["C"], 1)
        XCTAssertEqual(graph.laneCount, 2)
    }

    func testShallowBoundarySkipsMissingParents() {
        // Parent "ghost" is not in the list (shallow clone boundary).
        let commits = [commit("B", ["ghost"]), commit("A", ["ghost2"])]
        let graph = GitGraphLayout.layout(commits)
        XCTAssertTrue(graph.edges.isEmpty)
        XCTAssertEqual(graph.nodes.map(\.lane), [0, 1])
    }

    func testDeterministicAcrossRuns() {
        let commits = [
            commit("M", ["B", "C"]), commit("B", ["A"]), commit("C", ["A"]),
            commit("D", ["M"]), commit("E", ["D"]), commit("A", []),
        ]
        let first = GitGraphLayout.layout(commits)
        for _ in 0..<20 { XCTAssertEqual(GitGraphLayout.layout(commits), first) }
    }

    func testEmptyHistory() {
        let graph = GitGraphLayout.layout([])
        XCTAssertTrue(graph.nodes.isEmpty)
        XCTAssertEqual(graph.laneCount, 1)
    }
}

/// End-to-end against a real repository built in a temp dir (skipped without git).
final class GitClientTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        guard GitClient.executable() != nil else { throw XCTSkip("git not installed") }
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("ps-git-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: String...) throws { _ = try GitClient.run(args, in: repo) }
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "a@b.c")
        try git("config", "user.name", "Alice")
        try "one".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-qm", "first")
        try git("checkout", "-qb", "feature")
        try "feat".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-qm", "feature work")
        try git("checkout", "-q", "main")
        try "main".write(to: repo.appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-qm", "main work")
        try git("merge", "-q", "--no-ff", "feature", "-m", "merge feature")
        try git("tag", "v1.0")
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
    }

    func testIsRepository() {
        XCTAssertTrue(GitClient.isRepository(repo))
        XCTAssertFalse(GitClient.isRepository(FileManager.default.temporaryDirectory))
    }

    func testHashListAndCommitsRoundTrip() throws {
        let hashes = try GitClient.hashList(repo)
        XCTAssertEqual(hashes.count, 4)
        let commits = try GitClient.commits(repo, hashes: hashes)
        XCTAssertEqual(commits.count, 4)
        XCTAssertEqual(Set(commits.map(\.hash)), Set(hashes))
        let merge = try XCTUnwrap(commits.first { $0.subject == "merge feature" })
        XCTAssertEqual(merge.parents.count, 2)
        XCTAssertEqual(merge.authorName, "Alice")
    }

    func testRefsAndHead() throws {
        let refs = try GitClient.refs(repo)
        XCTAssertEqual(refs.head.branch, "main")
        XCTAssertFalse(refs.head.isDetached)
        XCTAssertNotNil(refs.head.commit)
        XCTAssertTrue(refs.refs.contains { $0.kind == .localBranch && $0.name == "feature" })
        XCTAssertTrue(refs.refs.contains { $0.kind == .tag && $0.name == "v1.0" })
        XCTAssertEqual(refs.byCommit[refs.head.commit!]?.contains { $0.name == "main" }, true)
    }

    func testDetachedHead() throws {
        _ = try GitClient.run(["checkout", "-q", "--detach", "HEAD"], in: repo)
        let refs = try GitClient.refs(repo)
        XCTAssertNil(refs.head.branch)
        XCTAssertTrue(refs.head.isDetached)
        XCTAssertNotNil(refs.head.commit)
    }

    func testEmptyRepository() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("ps-git-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        _ = try GitClient.run(["init", "-q", "-b", "main"], in: empty)
        XCTAssertTrue(GitClient.isRepository(empty))
        XCTAssertTrue(try GitClient.hashList(empty).isEmpty)
        let refs = try GitClient.refs(empty)
        XCTAssertNil(refs.head.commit)
        XCTAssertEqual(refs.head.branch, "main")
    }

    func testFileChangesAndDiff() throws {
        let hashes = try GitClient.hashList(repo)
        let commits = try GitClient.commits(repo, hashes: hashes)
        let merge = try XCTUnwrap(commits.first { $0.subject == "merge feature" })
        let changes = try GitClient.fileChanges(repo, commit: merge)
        XCTAssertEqual(changes.map(\.path), ["f.txt"])
        XCTAssertEqual(changes[0].status, .added)
        XCTAssertEqual(changes[0].added, 1)
        let diff = try GitClient.diff(repo, commit: merge, path: "f.txt")
        XCTAssertTrue(diff.contains("+feat"))

        let root = try XCTUnwrap(commits.first { $0.subject == "first" })
        let rootChanges = try GitClient.fileChanges(repo, commit: root)
        XCTAssertEqual(rootChanges.map(\.path), ["a.txt"])
        XCTAssertEqual(rootChanges[0].status, .added)
    }

    func testRenameDetection() throws {
        _ = try GitClient.run(["mv", "a.txt", "b.txt"], in: repo)
        _ = try GitClient.run(["commit", "-qm", "rename"], in: repo)
        let hashes = try GitClient.hashList(repo)
        let commits = try GitClient.commits(repo, hashes: hashes)
        let rename = try XCTUnwrap(commits.first { $0.subject == "rename" })
        let changes = try GitClient.fileChanges(repo, commit: rename)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].status, .renamed)
        XCTAssertEqual(changes[0].oldPath, "a.txt")
        XCTAssertEqual(changes[0].path, "b.txt")
    }

    func testBranchFilterAncestors() throws {
        let feature = try GitClient.ancestors(of: "feature", in: repo)
        XCTAssertEqual(feature.count, 2) // feature work + first
        let all = try GitClient.ancestors(of: "main", in: repo)
        XCTAssertEqual(all.count, 4)
    }

    func testCheckoutAndCreateBranch() throws {
        try GitClient.checkout(repo, "feature")
        let refs = try GitClient.refs(repo)
        XCTAssertEqual(refs.head.branch, "feature")
        try GitClient.createBranch(repo, "from-here", at: "HEAD")
        XCTAssertTrue(try GitClient.refs(repo).refs.contains { $0.name == "from-here" })
        XCTAssertThrowsError(try GitClient.createBranch(repo, "from-here", at: "HEAD"))
    }
}
