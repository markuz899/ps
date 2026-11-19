import Foundation

// MARK: - Models

public struct GitCommit: Equatable {
    public let hash: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    /// Unix timestamp.
    public let timestamp: TimeInterval
    public let subject: String
    public let body: String

    public var shortHash: String { String(hash.prefix(7)) }
    public var message: String { body.isEmpty ? subject : subject + "\n\n" + body }

    public init(hash: String, parents: [String], authorName: String, authorEmail: String, timestamp: TimeInterval, subject: String, body: String) {
        self.hash = hash
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.timestamp = timestamp
        self.subject = subject
        self.body = body
    }
}

public struct GitRef: Equatable {
    public enum Kind { case localBranch, remoteBranch, tag }
    /// Branch name without refs/heads/; remote as "origin/main"; tag name without refs/tags/.
    public let name: String
    public let kind: Kind
    public let commit: String
}

public struct GitHead: Equatable {
    /// nil on an unborn branch (repository without commits).
    public let commit: String?
    /// nil when HEAD is detached (or unborn).
    public let branch: String?
    public var isDetached: Bool { branch == nil && commit != nil }
}

public struct GitRefs {
    public let refs: [GitRef]
    public let head: GitHead
    /// All refs pointing at a commit, for badges.
    public let byCommit: [String: [GitRef]]

    public init(refs: [GitRef], head: GitHead) {
        self.refs = refs
        self.head = head
        var byCommit: [String: [GitRef]] = [:]
        for ref in refs { byCommit[ref.commit, default: []].append(ref) }
        self.byCommit = byCommit
    }
}

public enum GitFileStatus: Equatable {
    case added, modified, deleted, renamed, copied, other(String)
}

public struct GitFileChange: Equatable {
    public let path: String
    /// Set for renames/copies.
    public let oldPath: String?
    public let status: GitFileStatus
    /// nil for binary files.
    public let added: Int?
    public let deleted: Int?
}

public enum GitError: Error, Equatable {
    case gitNotFound
    case notARepository
    case commandFailed(String)
}

// MARK: - Parsers (pure, unit-tested)

/// Parsers for git's machine-readable output. Records are separated by 0x1E,
/// fields by 0x1F (both produced with %x1e / %x1f).
public enum GitParser {
    static let recordSeparator = "\u{1E}"
    static let fieldSeparator = "\u{1F}"

    /// `git log --format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b%x1e`
    public static func log(_ output: String) -> [GitCommit] {
        var commits: [GitCommit] = []
        for raw in output.split(separator: recordSeparator, omittingEmptySubsequences: true) {
            // git ends every record with "\x1e\n", so the newline lands at the start of the next one.
            let record = raw.trimmingCharacters(in: .newlines)
            let fields = record.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7, !fields[0].isEmpty else { continue }
            let parents = fields[1].isEmpty ? [] : fields[1].split(separator: " ").map(String.init)
            let time = TimeInterval(fields[4]) ?? 0
            let body = fields[6...].joined(separator: fieldSeparator).trimmingCharacters(in: .newlines)
            commits.append(GitCommit(
                hash: fields[0],
                parents: parents,
                authorName: fields[2],
                authorEmail: fields[3],
                timestamp: time,
                subject: fields[5],
                body: body
            ))
        }
        return commits
    }

    /// `git for-each-ref --format=%(refname)%1f%(*objectname)%1f%(objectname)%1e`
    /// (for-each-ref spells hex escapes `%1f`, not `%x1f` like git log)
    public static func refs(_ output: String) -> [GitRef] {
        var refs: [GitRef] = []
        for raw in output.split(separator: recordSeparator, omittingEmptySubsequences: true) {
            // git ends every record with "\x1e\n", so the newline lands at the start of the next one.
            let record = raw.trimmingCharacters(in: .newlines)
            let fields = record.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, fields[0].hasPrefix("refs/") else { continue }
            // Annotated tags: *objectname is the peeled commit.
            let commit = !fields[1].isEmpty ? fields[1] : fields[2]
            if commit.isEmpty { continue }
            let refname = fields[0]
            if refname.hasPrefix("refs/heads/") {
                refs.append(GitRef(name: String(refname.dropFirst("refs/heads/".count)), kind: .localBranch, commit: commit))
            } else if refname.hasPrefix("refs/remotes/") {
                refs.append(GitRef(name: String(refname.dropFirst("refs/remotes/".count)), kind: .remoteBranch, commit: commit))
            } else if refname.hasPrefix("refs/tags/") {
                refs.append(GitRef(name: String(refname.dropFirst("refs/tags/".count)), kind: .tag, commit: commit))
            }
        }
        return refs
    }

    /// `git diff-tree --name-status -z`: status and paths as NUL-separated fields;
    /// renames/copies carry two paths (old, new).
    public static func nameStatus(_ output: String) -> [(status: String, oldPath: String?, path: String)] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var result: [(String, String?, String)] = []
        var i = 0
        while i < fields.count {
            let status = fields[i]
            guard !status.isEmpty, status.allSatisfy({ $0.isLetter && $0.isUppercase || $0.isNumber }) else { i += 1; continue }
            i += 1
            if i >= fields.count { break }
            if status.hasPrefix("R") || status.hasPrefix("C") {
                guard i + 1 < fields.count else { break }
                result.append((status, fields[i], fields[i + 1]))
                i += 2
            } else {
                result.append((status, nil, fields[i]))
                i += 1
            }
        }
        return result
    }

    /// `git diff-tree --numstat -z`: `added<TAB>deleted<TAB>path` per NUL field;
    /// renames are `added<TAB>deleted<TAB>` + NUL + old + NUL + new; binary is `-`.
    public static func numstat(_ output: String) -> [(added: Int?, deleted: Int?, oldPath: String?, path: String)] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var result: [(Int?, Int?, String?, String)] = []
        var i = 0
        while i < fields.count {
            let field = fields[i]
            let parts = field.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { i += 1; continue }
            let added = Int(parts[0])
            let deleted = Int(parts[1])
            i += 1
            // A rename has no path after the counts (git writes "a\td\t", accept "a\td" too).
            if parts.count < 3 || parts[2].isEmpty, i + 1 < fields.count {
                // Rename: counts field carries no path, the next two fields are old and new.
                result.append((added, deleted, fields[i], fields[i + 1]))
                i += 2
            } else {
                result.append((added, deleted, nil, parts[2]))
            }
        }
        return result
    }

    public static func fileStatus(_ letter: String) -> GitFileStatus {
        switch letter.first {
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        default: return .other(letter)
        }
    }
}

// MARK: - Client

/// Talks to the system `git` binary. All `run` calls block, so they must be made
/// off the main thread (use `runAsync`); the parsers above are pure.
public enum GitClient {
    private static var cachedExecutable: URL?

    public static func executable() -> URL? {
        if let cachedExecutable { return cachedExecutable }
        var candidates: [String] = ["/usr/bin/git"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { $0 + "/git" }
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            let url = URL(fileURLWithPath: candidate)
            cachedExecutable = url
            return url
        }
        return nil
    }

    /// Runs git synchronously; returns stdout. Throws on failure with stderr in the error.
    @discardableResult
    public static func run(_ args: [String], in root: URL) throws -> String {
        guard let executable = executable() else { throw GitError.gitNotFound }
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        // Drain stderr concurrently so a chatty command can't deadlock on a full pipe.
        let group = DispatchGroup()
        group.enter()
        var errData = Data()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError.commandFailed(String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "git \(args.first ?? "") failed")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Runs git on a background queue; the completion runs on the main queue.
    public static func runAsync(_ args: [String], in root: URL, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try run(args, in: root) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    public static func isRepository(_ root: URL) -> Bool {
        (try? run(["rev-parse", "--git-dir"], in: root)) != nil
    }

    /// All commit hashes, newest first, parents after children (`--topo-order`).
    /// HEAD is added explicitly so a detached HEAD's history is included; on an
    /// unborn branch `rev-list HEAD` fails, hence the fallback.
    public static func hashList(_ root: URL) throws -> [String] {
        let output = try (try? run(["rev-list", "--topo-order", "--all", "HEAD"], in: root))
            ?? run(["rev-list", "--all", "--topo-order"], in: root)
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Commit metadata for the given hashes (order preserved by --no-walk=unsorted).
    public static func commits(_ root: URL, hashes: [String]) throws -> [GitCommit] {
        guard !hashes.isEmpty else { return [] }
        let format = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b%x1e"
        return GitParser.log(try run(["log", "--no-walk=unsorted", "--format=" + format] + hashes, in: root))
    }

    public static func refs(_ root: URL) throws -> GitRefs {
        let format = "%(refname)%1f%(*objectname)%1f%(objectname)%1e"
        let refs = GitParser.refs(try run(["for-each-ref", "--format=" + format], in: root))
        let branch = (try? run(["symbolic-ref", "-q", "--short", "HEAD"], in: root)).flatMap { $0.isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let commit = (try? run(["rev-parse", "HEAD"], in: root)).flatMap { $0.isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return GitRefs(refs: refs, head: GitHead(commit: commit, branch: branch))
    }

    /// Files changed by a commit, against its first parent (or against the empty
    /// tree for a root commit).
    public static func fileChanges(_ root: URL, commit: GitCommit) throws -> [GitFileChange] {
        let base = commit.parents.isEmpty ? ["--root", commit.hash] : [commit.parents[0], commit.hash]
        let names = GitParser.nameStatus(try run(["diff-tree", "--no-commit-id", "-r", "-M", "--name-status", "-z"] + base, in: root))
        let stats = GitParser.numstat(try run(["diff-tree", "--no-commit-id", "-r", "-M", "--numstat", "-z"] + base, in: root))
        var changes: [GitFileChange] = []
        for (i, entry) in names.enumerated() {
            let stat = i < stats.count ? stats[i] : nil
            changes.append(GitFileChange(
                path: entry.path,
                oldPath: entry.oldPath,
                status: GitParser.fileStatus(entry.status),
                added: stat?.added,
                deleted: stat?.deleted
            ))
        }
        return changes
    }

    /// Unified diff of one file in a commit, against its first parent.
    public static func diff(_ root: URL, commit: GitCommit, path: String) throws -> String {
        let base = commit.parents.isEmpty ? ["--root", commit.hash] : [commit.parents[0], commit.hash]
        return try run(["diff-tree", "-p", "--no-commit-id", "-r", "-M"] + base + ["--", path], in: root)
    }

    /// Hashes reachable from a ref (used for the branch filter).
    public static func ancestors(of ref: String, in root: URL) throws -> Set<String> {
        Set(try run(["rev-list", ref], in: root).split(separator: "\n").map(String.init))
    }

    /// Mutating actions; throw with git's stderr on failure.
    public static func checkout(_ root: URL, _ ref: String) throws {
        _ = try run(["checkout", ref], in: root)
    }

    public static func createBranch(_ root: URL, _ name: String, at commit: String) throws {
        _ = try run(["branch", name, commit], in: root)
    }
}
