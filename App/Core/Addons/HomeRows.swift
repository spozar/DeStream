import Foundation

/// Identifies a Home catalog row across launches, manifest refreshes and reconfiguration. Built from the addon's
/// manifest id (never its URL, which can hold secrets) plus the catalog's type and id.
struct HomeRowID: Hashable, Codable, Sendable {
    var manifestID: String
    var type: String
    var catalogID: String

    init(manifestID: String, type: String, catalogID: String) {
        self.manifestID = manifestID
        self.type = type
        self.catalogID = catalogID
    }

    init(addon: Addon, catalog: ManifestCatalog) {
        self.init(manifestID: addon.manifest.id, type: catalog.type, catalogID: catalog.id)
    }
}

/// User order and visibility of Home rows. `order` is empty until the user reorders; rows it doesn't list
/// (e.g. from a newly added addon) follow the listed ones in registry order. Entries for removed addons are kept,
/// so re-adding an addon restores its rows' visibility.
struct HomeRowPrefs: Codable, Equatable, Sendable {
    var order: [HomeRowID] = []
    var hidden: Set<HomeRowID> = []
    var showsContinueWatching = true
    var showsGenres = true
    var showsSuggestions = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent([HomeRowID].self, forKey: .order) ?? []
        hidden = try c.decodeIfPresent(Set<HomeRowID>.self, forKey: .hidden) ?? []
        showsContinueWatching = try c.decodeIfPresent(Bool.self, forKey: .showsContinueWatching) ?? true
        showsGenres = try c.decodeIfPresent(Bool.self, forKey: .showsGenres) ?? true
        showsSuggestions = try c.decodeIfPresent(Bool.self, forKey: .showsSuggestions) ?? true
    }

    var isDefault: Bool { self == HomeRowPrefs() }

    func isHidden(_ id: HomeRowID) -> Bool { hidden.contains(id) }

    /// All installed rows (hidden included) in user order. Stable: rows sharing a position keep registry order.
    func arranged<T>(_ installed: [T], id: (T) -> HomeRowID) -> [T] {
        var rank: [HomeRowID: Int] = [:]
        for (i, rowID) in order.enumerated() where rank[rowID] == nil { rank[rowID] = i }
        return installed.enumerated()
            .sorted { a, b in
                let ra = rank[id(a.element)] ?? Int.max, rb = rank[id(b.element)] ?? Int.max
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// The rows Home shows, in order.
    func visible<T>(_ installed: [T], id: (T) -> HomeRowID) -> [T] {
        arranged(installed, id: id).filter { !hidden.contains(id($0)) }
    }

    mutating func setHidden(_ id: HomeRowID, _ isHidden: Bool) {
        if isHidden { hidden.insert(id) } else { hidden.remove(id) }
    }

    /// `move(fromOffsets:toOffset:)` semantics over `arranged`, the current output of `arranged(_:id:)` as ids.
    mutating func move(fromOffsets: IndexSet, toOffset: Int, in arranged: [HomeRowID]) {
        let moving = fromOffsets.filter { arranged.indices.contains($0) }.map { arranged[$0] }
        guard !moving.isEmpty else { return }
        let insertAt = toOffset - fromOffsets.filter { $0 < toOffset }.count
        var rest = arranged.enumerated().filter { !fromOffsets.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        setOrder(rest)
    }

    /// Moves `id` past its nearest visible neighbour, skipping hidden rows so Home visibly changes.
    mutating func moveVisible(_ id: HomeRowID, up: Bool, in arranged: [HomeRowID]) {
        guard let from = arranged.firstIndex(of: id) else { return }
        let neighbours = up ? Array(arranged.indices.prefix(upTo: from).reversed()) : Array(arranged.indices.suffix(from: from + 1))
        guard let target = neighbours.first(where: { !hidden.contains(arranged[$0]) }) else { return }
        move(fromOffsets: [from], toOffset: up ? target : target + 1, in: arranged)
    }

    private mutating func setOrder(_ arranged: [HomeRowID]) {
        let installed = Set(arranged)
        var seen = Set<HomeRowID>()
        order = (arranged + order.filter { !installed.contains($0) }).filter { seen.insert($0).inserted }
    }
}
