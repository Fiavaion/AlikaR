import Foundation

/// What one device has found in one experience (PRD P8). Lives in a small
/// JSON file beside the bundle, never inside it, so sharing a bundle never
/// shares a player's progress.
public struct PlayerProgress: Codable, Sendable, Equatable {
    public var experienceId: String
    public var found: [String]
    public var states: [String: String]
    public var updated: String

    public init(experienceId: String) {
        self.experienceId = experienceId; self.found = []; self.states = [:]
        self.updated = ISO8601.string(from: Date())
    }

    public var foundSet: Set<String> { Set(found) }

    public mutating func apply(_ events: [EngineEvent], at date: Date = Date()) {
        var changed = false
        for e in events {
            switch e {
            case .found(let id) where !found.contains(id):
                found.append(id); changed = true
            case .state(let id, let value) where states[id] != value:
                states[id] = value; changed = true
            default: break
            }
        }
        if changed { updated = ISO8601.string(from: date) }
    }

    /// Counts towards the found badge (PRD P9). Audio-only elements are
    /// atmosphere, not things to find.
    public static func collectable(in x: Experience) -> [Element] {
        x.elements.filter { $0.kind != .audio }
    }

    public func foundCount(in x: Experience) -> (found: Int, total: Int) {
        let c = Self.collectable(in: x)
        return (c.filter { foundSet.contains($0.id) }.count, c.count)
    }
}

/// Reads and writes `PlayerProgress` beside a bundle folder:
/// `<id>.arhunt/` → `<id>.progress.json`.
public struct PlayerProgressStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    func url(for experienceId: String) -> URL {
        directory.appendingPathComponent("\(ExperienceBundle.slug(experienceId)).progress.json")
    }

    public func load(_ experienceId: String) -> PlayerProgress {
        guard let d = try? Data(contentsOf: url(for: experienceId)),
              let p = try? JSONDecoder().decode(PlayerProgress.self, from: d),
              p.experienceId == experienceId else { return PlayerProgress(experienceId: experienceId) }
        return p
    }

    public func save(_ p: PlayerProgress) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try e.encode(p).write(to: url(for: p.experienceId), options: .atomic)
    }

    public func reset(_ experienceId: String) throws {
        let u = url(for: experienceId)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }
}
