import Foundation

/// One entry of `git status`: a file with its staged (index) and unstaged (worktree) state.
public struct GitStatusEntry: Equatable {
    public let path: String
    /// Original path of a staged rename or copy.
    public let oldPath: String?
    /// X and Y of the porcelain format: " " unchanged, M, A, D, R, C, U (conflict), ? untracked.
    public let index: Character
    public let worktree: Character

    public var isUntracked: Bool { index == "?" }
    public var isConflicted: Bool { index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") }
    public var hasStagedChanges: Bool { !isUntracked && index != " " }
    public var hasUnstagedChanges: Bool { isUntracked || worktree != " " }
}

/// Lines changed in the working copy against HEAD, for the gutter.
public struct GitLineChanges: Equatable {
    public var added: IndexSet = []
    public var modified: IndexSet = []
    /// Lines after which something was deleted (0-based; -1 means before the first line).
    public var deletedAfter: IndexSet = []

    public init() {}
}

extension GitParser {
    /// `git status --porcelain=v1 -z`: "XY path" NUL, renames add the old path as the next field.
    public static func status(_ output: String) -> [GitStatusEntry] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [GitStatusEntry] = []
        var i = 0
        while i < fields.count {
            let field = fields[i]
            i += 1
            guard field.count > 3 else { continue }
            let x = field[field.startIndex]
            let y = field[field.index(after: field.startIndex)]
            let path = String(field.dropFirst(3))
            var oldPath: String?
            if x == "R" || x == "C", i < fields.count {
                oldPath = fields[i]
                i += 1
            }
            entries.append(GitStatusEntry(path: path, oldPath: oldPath, index: x, worktree: y))
        }
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Hunk headers of `git diff -U0`: `@@ -a,b +c,d @@`. Lines are 0-based in the new file.
    public static func lineChanges(_ diff: String) -> GitLineChanges {
        var changes = GitLineChanges()
        let header = try! NSRegularExpression(pattern: #"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#, options: .anchorsMatchLines)
        let text = diff as NSString
        for match in header.matches(in: diff, range: NSRange(location: 0, length: text.length)) {
            func number(_ group: Int, default value: Int) -> Int {
                let range = match.range(at: group)
                return range.location == NSNotFound ? value : Int(text.substring(with: range)) ?? value
            }
            let removed = number(1, default: 1)
            let start = number(2, default: 1)
            let added = number(3, default: 1)
            if added == 0 {
                // Pure deletion: `start` is the line before the gap.
                changes.deletedAfter.insert(start - 1)
            } else {
                let lines = (start - 1)..<(start - 1 + added)
                let modifiedCount = min(removed, added)
                changes.modified.insert(integersIn: lines.lowerBound..<(lines.lowerBound + modifiedCount))
                changes.added.insert(integersIn: (lines.lowerBound + modifiedCount)..<lines.upperBound)
            }
        }
        return changes
    }
}

extension GitClient {
    public static func status(_ root: URL) throws -> [GitStatusEntry] {
        GitParser.status(try run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root))
    }

    public static func stage(_ root: URL, paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try run(["add", "-A", "--"] + paths, in: root)
    }

    public static func unstage(_ root: URL, paths: [String]) throws {
        guard !paths.isEmpty else { return }
        // `restore --staged` needs a HEAD; before the first commit use `rm --cached`.
        if (try? run(["rev-parse", "--verify", "-q", "HEAD"], in: root)) != nil {
            try run(["restore", "--staged", "--"] + paths, in: root)
        } else {
            try run(["rm", "-q", "--cached", "-r", "--"] + paths, in: root)
        }
    }

    /// Throws `commandFailed` with git's message (nothing staged, no identity set…).
    public static func commit(_ root: URL, message: String) throws {
        try run(["commit", "-q", "-m", message], in: root)
    }

    public static func push(_ root: URL) throws -> String {
        try run(["push"], in: root)
    }

    public static func pull(_ root: URL) throws -> String {
        try run(["pull", "--ff-only"], in: root)
    }

    public static func currentBranch(_ root: URL) -> String? {
        (try? run(["symbolic-ref", "-q", "--short", "HEAD"], in: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unified diff of a working-copy file. `staged` compares the index with HEAD;
    /// otherwise the working copy with the index. Untracked files show as all added.
    public static func workingDiff(_ root: URL, entry: GitStatusEntry, staged: Bool) throws -> String {
        if entry.isUntracked {
            // `diff --no-index` exits with 1 when files differ, which is always here.
            let output = try? run(["diff", "--no-color", "--no-index", "--", "/dev/null", entry.path], in: root)
            if let output { return output }
            let contents = (try? String(contentsOf: root.appendingPathComponent(entry.path), encoding: .utf8)) ?? ""
            return "new file: \(entry.path)\n" + contents.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
        }
        let args = staged ? ["diff", "--no-color", "--cached", "--"] : ["diff", "--no-color", "--"]
        return try run(args + [entry.path], in: root)
    }

    /// Changed lines of a file against HEAD (staged and unstaged together), for the gutter.
    /// Nil when the file isn't tracked or isn't in a repository.
    public static func lineChanges(_ root: URL, path: String) -> GitLineChanges? {
        guard let diff = try? run(["diff", "--no-color", "--no-ext-diff", "-U0", "HEAD", "--", path], in: root) else { return nil }
        return GitParser.lineChanges(diff)
    }

    /// The repository's top folder for a path inside it.
    public static func topLevel(of folder: URL) -> URL? {
        guard let output = try? run(["rev-parse", "--show-toplevel"], in: folder) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}
