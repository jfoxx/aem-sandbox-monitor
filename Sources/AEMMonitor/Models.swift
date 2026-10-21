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
    /// Cloud Manager API account used for status and pipelines.
    /// nil = the original unauthenticated login-page check.
    var accountId: String? = nil
    /// IMS tenant (e.g. "foxx"), used for Cloud Manager deep links.
    var tenantId: String? = nil
}

/// An Adobe Developer Console OAuth Server-to-Server credential for the
/// Cloud Manager API. The client secret is NOT stored here; it lives in the
/// macOS Keychain under this account's id.
struct CloudManagerAccount: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var label: String           // e.g. "foxx org"
    var clientId: String        // a.k.a. API key
    var orgId: String           // e.g. "ABC123@AdobeOrg"
    var scopes: String          // comma-separated, copied from Developer Console

    static let defaultScopes = "openid,AdobeID,read_organizations,additional_info.projectedProductContext,read_pc.dma_aem_ams"
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
    /// Pipelines: also notify when each step starts (approval waits and the
    /// final result always notify).
    var pipelineSteps: Bool = false

    enum CodingKeys: String, CodingKey {
        case enabled, mode, sound, keepWatchingWhenUp, pipelineSteps
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
        pipelineSteps = try c.decodeIfPresent(Bool.self, forKey: .pipelineSteps) ?? d.pipelineSteps
    }
}

/// Top-level config file structure.
struct AppConfig: Codable, Equatable {
    var programs: [ProgramConfig]
    var notifications: NotificationSettings = NotificationSettings()
    var accounts: [CloudManagerAccount] = []

    enum CodingKeys: String, CodingKey {
        case programs, notifications, accounts
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
        accounts = try c.decodeIfPresent([CloudManagerAccount].self, forKey: .accounts) ?? []
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

/// Labels follow Cloud Manager's own wording ("Running", "Restarting") so
/// the menu matches what Cloud Manager shows.
enum EnvironmentStatus: Equatable {
    case unknown
    case checking
    case up
    case starting        // Cloud Manager "Restarting" (or login page not ready yet)
    case hibernated
    case updating        // Cloud Manager "Updating"
    case busy(String)    // other in-progress Cloud Manager states, with CM's label
    case failed(String)  // Cloud Manager failure states, with CM's label
    case down
    case error(String)   // transient: request failed, never notifies

    var label: String {
        switch self {
        case .unknown:         return "Unknown"
        case .checking:        return "Checking…"
        case .up:              return "Running"
        case .starting:        return "Restarting"
        case .hibernated:      return "Hibernated"
        case .updating:        return "Updating"
        case .busy(let l):     return l
        case .failed(let l):   return l
        case .down:            return "Down"
        case .error(let msg):  return "Error: \(msg)"
        }
    }

    var icon: String {
        switch self {
        case .unknown:    return "⚫"
        case .checking:   return "🟡"
        case .up:         return "🟢"
        case .starting:   return "🟠"
        case .hibernated: return "⚫"
        case .updating:   return "🟠"
        case .busy:       return "🟠"
        case .failed:     return "🔴"
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
             (.updating, .updating),
             (.down, .down):
            return true
        case (.busy(let a), .busy(let b)),
             (.failed(let a), .failed(let b)),
             (.error(let a), .error(let b)):
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
    let accountId: String?
    let tenantId: String?
    var environments: [AEMEnvironment]

    init(config: ProgramConfig) {
        self.id = config.id
        self.name = config.name
        self.accountId = config.accountId
        self.tenantId = config.tenantId
        self.environments = config.environments.map { AEMEnvironment(programId: config.id, config: $0) }
    }
}

// MARK: - Runtime Pipeline (Cloud Manager API only)

struct PipelineRuntime: Identifiable {
    var id: String { "\(programId)-\(pipelineId)" }
    let programId: String
    let pipelineId: String
    var name: String
    var pipelineStatus: String          // IDLE / BUSY / WAITING
    var execution: CMExecution? = nil
    var isWatching: Bool = false
    var lastCheck: Date? = nil
    var error: String? = nil

    var summary: String {
        if let error { return "Error: \(error)" }
        guard let execution else { return pipelineStatus == "BUSY" ? "Running" : "No runs yet" }
        return execution.summary
    }

    var isActive: Bool {
        if let execution { return !execution.isTerminal }
        return pipelineStatus == "BUSY" || pipelineStatus == "WAITING"
    }
}
