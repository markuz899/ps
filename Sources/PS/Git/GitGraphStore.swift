import AppKit
import PSCore

/// Owns the git data of the open folder: paged loading off the main thread,
/// pure layout from PSCore, and the text/branch filters. All callbacks on main.
final class GitGraphStore {
    enum State: Equatable {
        case idle
        case notARepository
        case empty
        case ready
    }

    static let pageSize = 500

    /// Called on the main queue whenever the visible data changes.
    var onChange: (() -> Void)?

    private(set) var state: State = .idle
    private(set) var commits: [GitCommit] = []
    private(set) var refs: GitRefs?
    private(set) var graph: GitGraph = GitGraphLayout.layout([])
    /// Indices into `commits` that pass the current filters.
    private(set) var visible: [Int] = []
    private(set) var hasMore = false

    var root: URL? {
        didSet {
            if root != oldValue { reload() }
        }
    }

    // MARK: Filters

    var query = "" {
        didSet { applyFilters() }
    }

    /// nil = all branches; otherwise the selected branch names (local short names
    /// and remotes as "origin/main").
    var selectedBranches: Set<String>? {
        didSet { reloadBranchFilter() }
    }

    private var branchHashes: Set<String> = []
    private var generation = 0
    private var branchGeneration = 0
    private var reloadWork: DispatchWorkItem?

    // MARK: Loading

    func reload() {
        generation += 1
        isLoadingPage = false
        let token = generation
        guard let root else {
            state = .idle
            commits = []
            refs = nil
            graph = GitGraphLayout.layout([])
            visible = []
            hasMore = false
            onChange?()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard GitClient.isRepository(root) else {
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    self.state = .notARepository
                    self.commits = []
                    self.refs = nil
                    self.graph = GitGraphLayout.layout([])
                    self.visible = []
                    self.hasMore = false
                    self.onChange?()
                }
                return
            }
            let result = Result { () -> ([String], GitRefs) in
                let hashes = try GitClient.hashList(root)
                let refs = try GitClient.refs(root)
                return (hashes, refs)
            }
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                switch result {
                case let .success((hashes, refs)):
                    self.allHashes = hashes
                    self.refs = refs
                    self.state = hashes.isEmpty ? .empty : .ready
                    self.loadedCount = 0
                    self.commits = []
                    if hashes.isEmpty {
                        self.graph = GitGraphLayout.layout([])
                        self.hasMore = false
                        self.applyFilters()
                    } else {
                        self.loadNextPage(token: token, root: root)
                    }
                case .failure:
                    self.state = .notARepository
                    self.onChange?()
                }
            }
        }
    }

    private var allHashes: [String] = []
    private var loadedCount = 0
    private var isLoadingPage = false

    /// Loads the next page of commits. `token` guards against stale reloads.
    func loadMore() {
        guard let root, hasMore, state == .ready, !isLoadingPage else { return }
        loadNextPage(token: generation, root: root)
    }

    private func loadNextPage(token: Int, root: URL) {
        let start = loadedCount
        let end = min(start + GitGraphStore.pageSize, allHashes.count)
        guard start < end else { return }
        isLoadingPage = true
        hasMore = end < allHashes.count
        let batch = Array(allHashes[start..<end])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result { try GitClient.commits(root, hashes: batch) }
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.isLoadingPage = false
                if case let .success(page) = result {
                    self.commits.append(contentsOf: page)
                    self.loadedCount = end
                    self.graph = GitGraphLayout.layout(self.commits)
                }
                self.applyFilters() // notifies onChange
            }
        }
    }

    // MARK: Refresh (repository changed on disk)

    /// Debounced: FSEvents fires many events for one git operation.
    func notifyRepoChanged() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Filters

    private func reloadBranchFilter() {
        branchGeneration += 1
        let token = branchGeneration
        guard let root, let selected = selectedBranches, !selected.isEmpty else {
            branchHashes = []
            applyFilters()
            return
        }
        let names = Array(selected)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var union = Set<String>()
            for name in names {
                if let ancestors = try? GitClient.ancestors(of: name, in: root) {
                    union.formUnion(ancestors)
                }
            }
            DispatchQueue.main.async {
                guard self.branchGeneration == token else { return }
                self.branchHashes = union
                self.applyFilters()
            }
        }
    }

    private func applyFilters() {
        let query = query.lowercased()
        let filteringBranches = selectedBranches != nil
        visible = commits.indices.filter { i in
            if filteringBranches && !branchHashes.contains(commits[i].hash) { return false }
            if query.isEmpty { return true }
            let c = commits[i]
            return c.subject.lowercased().contains(query)
                || c.body.lowercased().contains(query)
                || c.authorName.lowercased().contains(query)
                || c.authorEmail.lowercased().contains(query)
                || c.hash.lowercased().contains(query)
        }
        onChange?()
    }

    // MARK: Lookups

    func commit(atVisibleRow row: Int) -> GitCommit? {
        guard visible.indices.contains(row) else { return nil }
        return commits[visible[row]]
    }

    func node(atVisibleRow row: Int) -> GitGraphNode? {
        guard visible.indices.contains(row) else { return nil }
        return graph.nodes[visible[row]]
    }

    func graphRow(atVisibleRow row: Int) -> GitGraphRow? {
        guard visible.indices.contains(row) else { return nil }
        return graph.rows[visible[row]]
    }

    func index(ofHash hash: String) -> Int? {
        commits.firstIndex { $0.hash == hash }
    }

    func refs(forCommit hash: String) -> [GitRef] {
        refs?.byCommit[hash] ?? []
    }

    func isHead(_ hash: String) -> Bool {
        refs?.head.commit == hash
    }

    var currentBranch: String? { refs?.head.branch }
}
