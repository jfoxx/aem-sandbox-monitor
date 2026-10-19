import Foundation

// MARK: - Persisted Configuration (Codable)

/// A single environment entry as stored on disk.
struct EnvironmentConfig: Codable, Identifiable, Equatable {
    var id: String       // environment ID, e.g. "1429146"
    var name: String     // "dev", "stage", "prod", etc.
}

/// A program entry as stored on disk.
struct ProgramConfig: Codable, Identifiable, Equatable {
    var id: String       // program ID, e.g. "49252"
    var name: String     // display name, e.g. "foxx"
    var environments: [EnvironmentConfig]
}

/// Which status changes produce a macOS notification.
enum NotifyMode: String, Codable, CaseIterable {
    case allChanges   // any settled change: hibernated / starting / up / down
    case wakeOnly     // only when an environment becomes fully up
}

/// User-configurable notification behaviour, persisted alongside programs.
struct NotificationSettings: Codable, Equatable {
    var enabled: Bool = true
    var mode: NotifyMode = .allChanges
    var sound: Bool = true
    /// When false (original behaviour) watching stops once an environment is up.
    /// When true, polling continues so a later hibernation is also reported.
    var keepWatchingWhenUp: Bool = false

    enum CodingKeys: String, CodingKey {
        case enabled, mode, sound, keepWatchingWhenUp
    }
}

extension NotificationSettings {
    /// Tolerant decoding: any missing key falls back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        mode = try c.decodeIfPresent(NotifyMode.self, forKey: .mode) ?? d.mode
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? d.sound
        keepWatchingWhenUp = try c.decodeIfPresent(Bool.self, forKey: .keepWatchingWhenUp) ?? d.keepWatchingWhenUp
    }
}

/// Top-level config file structure.
struct AppConfig: Codable, Equatable {
    var programs: [ProgramConfig]
    var notifications: NotificationSettings = NotificationSettings()

    enum CodingKeys: String, CodingKey {
        case programs, notifications
    }

    static let empty = AppConfig(programs: [])

    static let defaults = AppConfig(programs: [])
}

extension AppConfig {
    /// Tolerant decoding so config.json files written by 1.0 (no
    /// "notifications" key) still load instead of being treated as first launch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        programs = try c.decode([ProgramConfig].self, forKey: .programs)
        notifications = try c.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
    }
}

// MARK: - Config Store (JSON file persistence)

enum ConfigStore {

    private static var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AEMMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// Load config from disk. Returns nil if no file exists (first launch).
    static func load() -> AppConfig? {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    /// Save config to disk.
    static func save(_ config: AppConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configURL, options: .atomic)
    }
}

// MARK: - Runtime Status

enum EnvironmentStatus: Equatable {
    case unknown
    case checking
    case up
    case starting    // de-hibernating: no "hibernated" text, but no login form yet
    case hibernated
    case down
    case error(String)

    var label: String {
        switch self {
        case .unknown:        return "Unknown"
        case .checking:       return "Checking…"
        case .up:             return "Up"
        case .starting:       return "Starting"
        case .hibernated:     return "Hibernated"
        case .down:           return "Down"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var icon: String {
        switch self {
        case .unknown:    return "⚫"
        case .checking:   return "🟡"
        case .up:         return "🟢"
        case .starting:   return "🟠"
        case .hibernated: return "⚫"
        case .down:       return "🔴"
        case .error:      return "🔴"
        }
    }

    static func == (lhs: EnvironmentStatus, rhs: EnvironmentStatus) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown),
             (.checking, .checking),
             (.up, .up),
             (.starting, .starting),
             (.hibernated, .hibernated),
             (.down, .down):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Runtime Environment (config + transient state)

struct AEMEnvironment: Identifiable {
    let id: String          // composite key: "{programId}-{envId}"
    let name: String
    let programId: String
    let envId: String
    var status: EnvironmentStatus = .unknown
    var isWatching: Bool = false
    var lastCheck: Date? = nil
    var secondsUntilNext: Int = 0

    var url: URL {
        URL(string: "https://author-p\(programId)-e\(envId).adobeaemcloud.com/libs/granite/core/content/login.html")!
    }

    /// Author root, opened when the user clicks a notification.
    var authorURL: URL {
        URL(string: "https://author-p\(programId)-e\(envId).adobeaemcloud.com/")!
    }

    var displayLabel: String {
        "\(name) (\(envId))"
    }

    init(programId: String, config: EnvironmentConfig) {
        self.id = "\(programId)-\(config.id)"
        self.name = config.name
        self.programId = programId
        self.envId = config.id
    }
}

// MARK: - Runtime Program (config + runtime environments)

struct AEMProgram: Identifiable {
    let id: String
    let name: String
    var environments: [AEMEnvironment]

    init(config: ProgramConfig) {
        self.id = config.id
        self.name = config.name
        self.environments = config.environments.map { AEMEnvironment(programId: config.id, config: $0) }
    }
}
