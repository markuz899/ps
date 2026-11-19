import Foundation

// MARK: - Palette

/// Lane colours. Mid-saturation hues chosen to keep contrast on both light and
/// dark backgrounds; index 0 is the "main" lane.
public enum GitBranchPalette {
    public static let colors: [String] = [
        "#3B82F6", // blue
        "#F59E0B", // orange
        "#22C55E", // green
        "#A855F7", // purple
        "#EC4899", // pink
        "#06B6D4", // cyan
        "#84CC16", // lime
        "#EF4444", // red
    ]

    public static func color(index: Int) -> String {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

// MARK: - Graph model

public struct GitGraphNode: Equatable {
    public let lane: Int
    public let colorIndex: Int
}

public struct GitGraphEdge: Equatable {
    /// Index into the commits array (newest first): edge goes from `from` (child) down to `to` (parent).
    public let from: Int
    public let to: Int
    public let fromLane: Int
    public let toLane: Int
    public let colorIndex: Int
}

/// Per-row drawing data derived from the edges: which lanes have a vertical line
/// crossing the whole row, which edges curve out of the row's node (child side)
/// and which curve into it (parent side).
public struct GitGraphRow: Equatable {
    public var verticals: [(lane: Int, colorIndex: Int)] = []
    public var outgoing: [(fromLane: Int, toLane: Int, colorIndex: Int)] = []
    public var incoming: [(lane: Int, colorIndex: Int)] = []

    // Tuples aren't Equatable, so the comparison can't be synthesized.
    public static func == (a: GitGraphRow, b: GitGraphRow) -> Bool {
        a.verticals.elementsEqual(b.verticals) { $0 == $1 }
            && a.outgoing.elementsEqual(b.outgoing) { $0 == $1 }
            && a.incoming.elementsEqual(b.incoming) { $0 == $1 }
    }
}

public struct GitGraph: Equatable {
    public let nodes: [GitGraphNode]
    public let edges: [GitGraphEdge]
    public let rows: [GitGraphRow]
    public let laneCount: Int
}

// MARK: - Layout

/// Pure layout: assigns each commit a lane and each parent edge a lane and a
/// stable colour. Deterministic — the same input always produces the same graph,
/// so colours survive scrolling and refreshes. Commits must be newest first with
/// parents after children (git rev-list --topo-order).
public enum GitGraphLayout {
    public static func layout(_ commits: [GitCommit]) -> GitGraph {
        let index = Dictionary(commits.enumerated().map { ($1.hash, $0) }, uniquingKeysWith: { first, _ in first })
        var pending: [Int: String] = [:]   // lane -> hash the lane is waiting for
        var laneColor: [Int: Int] = [:]
        var freeLanes: [Int] = []
        var nextLane = 0
        var nodes: [GitGraphNode] = []
        var edges: [GitGraphEdge] = []

        func allocate() -> Int {
            let lane: Int
            if !freeLanes.isEmpty {
                lane = freeLanes.removeFirst()
            } else {
                lane = nextLane
                nextLane += 1
            }
            // Smallest colour not used by an active lane, so neighbours always differ.
            let used = Set(laneColor.values)
            var color = 0
            while color < GitBranchPalette.colors.count && used.contains(color) { color += 1 }
            laneColor[lane] = color % GitBranchPalette.colors.count
            return lane
        }

        for (i, commit) in commits.enumerated() {
            let lane: Int
            if let match = pending.filter({ $0.value == commit.hash }).keys.min() {
                lane = match
                pending.removeValue(forKey: lane)
            } else {
                lane = allocate()
            }
            nodes.append(GitGraphNode(lane: lane, colorIndex: laneColor[lane] ?? 0))

            for (j, parent) in commit.parents.enumerated() {
                guard let to = index[parent] else { continue } // shallow boundary: parent not loaded
                let toLane: Int
                if j == 0 {
                    // The first parent continues in the commit's own lane.
                    pending[lane] = parent
                    toLane = lane
                } else if let existing = pending.filter({ $0.value == parent }).keys.min() {
                    toLane = existing
                } else {
                    toLane = allocate()
                    pending[toLane] = parent
                }
                edges.append(GitGraphEdge(from: i, to: to, fromLane: lane, toLane: toLane, colorIndex: laneColor[toLane] ?? 0))
            }

            // Lanes that are neither the current one nor waiting for a commit are free again.
            for l in laneColor.keys where l != lane && pending[l] == nil {
                laneColor.removeValue(forKey: l)
                freeLanes.append(l)
                freeLanes.sort()
            }
        }

        var rows = [GitGraphRow](repeating: GitGraphRow(), count: commits.count)
        for edge in edges {
            if edge.fromLane != edge.toLane {
                rows[edge.from].outgoing.append((edge.fromLane, edge.toLane, edge.colorIndex))
            }
            if edge.toLane != nodes[edge.to].lane {
                rows[edge.to].incoming.append((edge.toLane, edge.colorIndex))
            }
            for r in stride(from: edge.from + 1, to: edge.to, by: 1) {
                rows[r].verticals.append((edge.toLane, edge.colorIndex))
            }
        }

        return GitGraph(nodes: nodes, edges: edges, rows: rows, laneCount: max(nextLane, 1))
    }
}
