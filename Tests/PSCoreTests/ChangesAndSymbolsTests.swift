import XCTest
@testable import PSCore

final class GitChangesTests: XCTestCase {
    func testStatusParsing() {
        let output = " M src/a.swift\0A  new.txt\0R  b.txt\0old-b.txt\0?? notes/todo.md\0UU conflict.c\0"
        let entries = GitParser.status(output)
        XCTAssertEqual(entries.map(\.path), ["b.txt", "conflict.c", "new.txt", "notes/todo.md", "src/a.swift"])
        let renamed = entries[0]
        XCTAssertEqual(renamed.oldPath, "old-b.txt")
        XCTAssertTrue(renamed.hasStagedChanges)
        XCTAssertFalse(renamed.hasUnstagedChanges)
        XCTAssertTrue(entries[1].isConflicted)
        XCTAssertTrue(entries[3].isUntracked && entries[3].hasUnstagedChanges && !entries[3].hasStagedChanges)
        XCTAssertTrue(entries[4].hasUnstagedChanges && !entries[4].hasStagedChanges)
    }

    func testLineChangesFromHunks() {
        let diff = """
        diff --git a/f b/f
        @@ -2 +2 @@
        -old
        +new
        @@ -5,0 +6,2 @@
        +added one
        +added two
        @@ -10,2 +11,0 @@
        -gone
        -gone too
        @@ -20,1 +19,3 @@
        """
        let changes = GitParser.lineChanges(diff)
        XCTAssertEqual(Array(changes.modified), [1, 18])
        XCTAssertEqual(Array(changes.added), [5, 6, 19, 20])
        XCTAssertEqual(Array(changes.deletedAfter), [10])
    }
}

final class GitWorkingCopyTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        guard GitClient.executable() != nil else { throw XCTSkip("git not installed") }
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("ps-scm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try GitClient.run(["init", "-q", "-b", "main"], in: repo)
        try GitClient.run(["config", "user.email", "a@b.c"], in: repo)
        try GitClient.run(["config", "user.name", "Alice"], in: repo)
        try "one\ntwo\nthree\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try GitClient.run(["add", "."], in: repo)
        try GitClient.run(["commit", "-qm", "first"], in: repo)
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
    }

    func testStageUnstageCommit() throws {
        try "one\nTWO\nthree\nfour\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        var status = try GitClient.status(repo)
        XCTAssertEqual(status.map(\.path), ["a.txt", "b.txt"])
        XCTAssertTrue(status[1].isUntracked)

        let lines = try XCTUnwrap(GitClient.lineChanges(repo, path: "a.txt"))
        XCTAssertEqual(Array(lines.modified), [1])
        XCTAssertEqual(Array(lines.added), [3])

        XCTAssertTrue(try GitClient.workingDiff(repo, entry: status[1], staged: false).contains("+new"))
        try GitClient.stage(repo, paths: ["b.txt"])
        status = try GitClient.status(repo)
        XCTAssertTrue(status[1].hasStagedChanges && !status[1].hasUnstagedChanges)
        try GitClient.unstage(repo, paths: ["b.txt"])
        XCTAssertTrue(try GitClient.status(repo)[1].isUntracked)

        try GitClient.stage(repo, paths: ["a.txt", "b.txt"])
        try GitClient.commit(repo, message: "second")
        XCTAssertTrue(try GitClient.status(repo).isEmpty)
        XCTAssertEqual(try GitClient.run(["log", "-1", "--format=%s"], in: repo).trimmingCharacters(in: .newlines), "second")
        XCTAssertThrowsError(try GitClient.commit(repo, message: "nothing staged"))
    }
}

final class SymbolIndexTests: XCTestCase {
    func testFindsDeclarationsAcrossFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ps-symbols-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = folder.appendingPathComponent("UserService.ts")
        let controller = folder.appendingPathComponent("UserController.ts")
        let swift = folder.appendingPathComponent("Model.swift")
        try "export class UserService {\n  async loadUsers(id: string): Promise<User[]> {\n    return []\n  }\n}\n\nexport function formatUser(u) { return u }\n".write(to: service, atomically: true, encoding: .utf8)
        try "import { UserService } from './UserService'\nconst users = await service.loadUsers(id)\n".write(to: controller, atomically: true, encoding: .utf8)
        try "extension Greeter {\n    func loadUsers() {}\n}\n".write(to: swift, atomically: true, encoding: .utf8)

        let index = SymbolIndex()
        index.update([service, controller, swift])
        let found = index.definitions(of: "loadUsers", preferring: controller)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first?.url, service, "same language first")
        XCTAssertEqual(found.first?.line, 1)
        XCTAssertEqual(index.definitions(of: "formatUser").first?.line, 6)
        XCTAssertEqual(index.definitions(of: "UserService").first?.line, 0)
        XCTAssertTrue(index.names(withPrefix: "form").contains("formatUser"))

        // Deleting a file removes its declarations.
        try FileManager.default.removeItem(at: service)
        index.update(service)
        XCTAssertEqual(index.definitions(of: "loadUsers").map(\.url), [swift])
    }
}
