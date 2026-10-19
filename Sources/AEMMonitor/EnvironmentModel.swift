import Foundation
import UserNotifications
import Combine
import AppKit

/// Central observable model that owns the program/environment list,
/// manages polling timers, dispatches notifications, and persists config.
@MainActor
final class EnvironmentModel: ObservableObject {

    // MARK: - Published state

    @Published var programs: [AEMProgram] = []
    @Published var lastGlobalCheck: Date? = nil
    @Published var showSettings: Bool = false

    /// The persisted configuration (source of truth for structure).
    @Published var config: AppConfig = .empty

    /// Callback the AppDelegate hooks into to flash the menu bar icon.
    var onEnvironmentWokeUp: (() -> Void)?

    /// macOS notification permission, refreshed on launch and from Settings.
    @Published var notificationAuthorization: UNAuthorizationStatus = .notDetermined

    /// macOS-level banner style for this app (.none means delivered silently
    /// to Notification Center only, with no banner).
    @Published var notificationAlertStyle: UNAlertStyle = .none

    /// Last error reported by UNUserNotificationCenter, shown in Settings so
    /// failures are never silent.
    @Published var lastNotificationError: String? = nil

    /// Time the last notification was handed to macOS successfully.
    @Published var lastNotificationSent: Date? = nil

    // MARK: - Internals

    private let pollInterval: TimeInterval = 30
    private var timers: [String: Timer] = [:]          // env composite id → Timer
    private var countdownTimers: [String: Timer] = [:]  // env composite id → 1-sec ticker

    /// Last *settled* status per watched environment (never .checking or
    /// .error). Used to detect transitions; cleared when a watch stops so a
    /// new watch starts from a fresh baseline.
    private var lastSettled: [String: EnvironmentStatus] = [:]

    // MARK: - Init

    init() {
        if let saved = ConfigStore.load() {
            self.config = saved
            self.programs = saved.programs.map { AEMProgram(config: $0) }
        } else {
            // First launch — use defaults and prompt settings.
            self.config = AppConfig.defaults
            self.programs = AppConfig.defaults.programs.map { AEMProgram(config: $0) }
            ConfigStore.save(config)
            showSettings = true
        }
    }

    /// Whether this is a "fresh" config (no programs yet).
    var isEmpty: Bool { programs.isEmpty }

    // MARK: - Computed helpers

    var anyWatching: Bool {
        programs.flatMap(\.environments).contains { $0.isWatching }
    }

    // MARK: - Config mutations (CRUD)

    /// Rebuild runtime programs from config, preserving any active watch state.
    private func rebuildPrograms() {
        // Snapshot current watch/status state keyed by composite id.
        var stateMap: [String: (EnvironmentStatus, Bool, Date?, Int)] = [:]
        for prog in programs {
            for env in prog.environments {
                stateMap[env.id] = (env.status, env.isWatching, env.lastCheck, env.secondsUntilNext)
            }
        }

        programs = config.programs.map { pc in
            var prog = AEMProgram(config: pc)
            for i in prog.environments.indices {
                if let state = stateMap[prog.environments[i].id] {
                    prog.environments[i].status = state.0
                    prog.environments[i].isWatching = state.1
                    prog.environments[i].lastCheck = state.2
                    prog.environments[i].secondsUntilNext = state.3
                }
            }
            return prog
        }
    }

    func addProgram(name: String, id: String) {
        let pc = ProgramConfig(id: id, name: name, environments: [])
        config.programs.append(pc)
        ConfigStore.save(config)
        rebuildPrograms()
    }

    func updateProgram(at index: Int, name: String, id: String) {
        guard config.programs.indices.contains(index) else { return }
        // Stop any watches in this program before changing IDs.
        stopAllInProgram(index)
        config.programs[index].name = name
        config.programs[index].id = id
        // Re-key environment composite ids since program id may have changed.
        ConfigStore.save(config)
        rebuildPrograms()
    }

    func removeProgram(at index: Int) {
        guard config.programs.indices.contains(index) else { return }
        stopAllInProgram(index)
        config.programs.remove(at: index)
        ConfigStore.save(config)
        rebuildPrograms()
    }

    func addEnvironment(toProgramAt pi: Int, name: String, id: String) {
        guard config.programs.indices.contains(pi) else { return }
        let ec = EnvironmentConfig(id: id, name: name)
        config.programs[pi].environments.append(ec)
        ConfigStore.save(config)
        rebuildPrograms()
    }

    func updateEnvironment(programAt pi: Int, envAt ei: Int, name: String, id: String) {
        guard config.programs.indices.contains(pi),
              config.programs[pi].environments.indices.contains(ei) else { return }
        // Stop watch on old env if active.
        let oldComposite = "\(config.programs[pi].id)-\(config.programs[pi].environments[ei].id)"
        stopWatchByCompositeId(oldComposite)
        config.programs[pi].environments[ei].name = name
        config.programs[pi].environments[ei].id = id
        ConfigStore.save(config)
        rebuildPrograms()
    }

    func removeEnvironment(programAt pi: Int, envAt ei: Int) {
        guard config.programs.indices.contains(pi),
              config.programs[pi].environments.indices.contains(ei) else { return }
        let composite = "\(config.programs[pi].id)-\(config.programs[pi].environments[ei].id)"
        stopWatchByCompositeId(composite)
        config.programs[pi].environments.remove(at: ei)
        ConfigStore.save(config)
        rebuildPrograms()
    }

    // MARK: - Notification settings

    var notificationSettings: NotificationSettings { config.notifications }

    func updateNotificationSettings(_ change: (inout NotificationSettings) -> Void) {
        change(&config.notifications)
        ConfigStore.save(config)
    }

    // MARK: - Polling actions

    func startWatching(programIndex: Int, envIndex: Int) {
        guard programs.indices.contains(programIndex),
              programs[programIndex].environments.indices.contains(envIndex) else { return }
        let envId = programs[programIndex].environments[envIndex].id
        guard timers[envId] == nil else { return }

        programs[programIndex].environments[envIndex].isWatching = true
        programs[programIndex].environments[envIndex].secondsUntilNext = 0

        // Immediate check.
        poll(programIndex: programIndex, envIndex: envIndex)

        // Repeating poll.
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll(programIndex: programIndex, envIndex: envIndex)
            }
        }
        timers[envId] = timer

        // Countdown ticker.
        programs[programIndex].environments[envIndex].secondsUntilNext = Int(pollInterval)
        let cd = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.programs.indices.contains(programIndex),
                      self.programs[programIndex].environments.indices.contains(envIndex) else { return }
                let current = self.programs[programIndex].environments[envIndex].secondsUntilNext
                if current > 0 {
                    self.programs[programIndex].environments[envIndex].secondsUntilNext = current - 1
                }
            }
        }
        countdownTimers[envId] = cd
    }

    func stopWatching(programIndex: Int, envIndex: Int) {
        guard programs.indices.contains(programIndex),
              programs[programIndex].environments.indices.contains(envIndex) else { return }
        let envId = programs[programIndex].environments[envIndex].id
        stopWatchByCompositeId(envId)
        programs[programIndex].environments[envIndex].isWatching = false
        programs[programIndex].environments[envIndex].secondsUntilNext = 0
    }

    func watchAll() {
        for pi in programs.indices {
            for ei in programs[pi].environments.indices {
                let env = programs[pi].environments[ei]
                if !env.isWatching && env.status != .up {
                    startWatching(programIndex: pi, envIndex: ei)
                }
            }
        }
    }

    func stopAll() {
        for pi in programs.indices {
            for ei in programs[pi].environments.indices {
                if programs[pi].environments[ei].isWatching {
                    stopWatching(programIndex: pi, envIndex: ei)
                }
            }
        }
    }

    // MARK: - Private helpers

    private func stopAllInProgram(_ pi: Int) {
        guard programs.indices.contains(pi) else { return }
        for ei in programs[pi].environments.indices {
            if programs[pi].environments[ei].isWatching {
                stopWatching(programIndex: pi, envIndex: ei)
            }
        }
    }

    private func stopWatchByCompositeId(_ compositeId: String) {
        timers[compositeId]?.invalidate()
        timers.removeValue(forKey: compositeId)
        countdownTimers[compositeId]?.invalidate()
        countdownTimers.removeValue(forKey: compositeId)
        lastSettled.removeValue(forKey: compositeId)
    }

    private func poll(programIndex pi: Int, envIndex ei: Int) {
        guard programs.indices.contains(pi),
              programs[pi].environments.indices.contains(ei) else { return }
        let env = programs[pi].environments[ei]
        programs[pi].environments[ei].status = .checking
        Task {
            let result = await EnvironmentChecker.check(url: env.url)
            // Bounds-check again — config may have changed during the await.
            guard self.programs.indices.contains(pi),
                  self.programs[pi].environments.indices.contains(ei),
                  self.programs[pi].environments[ei].id == env.id else { return }

            programs[pi].environments[ei].status = result
            programs[pi].environments[ei].lastCheck = Date()
            programs[pi].environments[ei].secondsUntilNext = Int(pollInterval)
            lastGlobalCheck = Date()

            // Transient errors (timeouts, network blips) are shown inline but
            // never notify and never move the baseline, so a single dropped
            // request does not produce a pair of spurious notifications.
            if case .error(_) = result { return }

            let previous = lastSettled[env.id]   // nil on the first poll of a watch
            lastSettled[env.id] = result
            let settings = config.notifications
            let programName = programs[pi].name

            if result == .up {
                // Notify on wake, including "already up" on the first poll
                // (the original 1.0 behaviour), but not on every poll while
                // it stays up when keepWatchingWhenUp is on.
                if previous != .up {
                    sendNotification(env: env, programName: programName,
                                     from: previous, to: result, settings: settings)
                    onEnvironmentWokeUp?()
                }
                if !settings.keepWatchingWhenUp {
                    stopWatching(programIndex: pi, envIndex: ei)
                }
            } else if let previous, previous != result, settings.mode == .allChanges {
                sendNotification(env: env, programName: programName,
                                 from: previous, to: result, settings: settings)
            }
        }
    }

    // MARK: - Notifications

    /// True when running as a real .app bundle. `swift run` has no bundle
    /// identifier and UNUserNotificationCenter would crash there.
    var canUseNotificationCenter: Bool { Bundle.main.bundleIdentifier != nil }

    func requestNotificationPermission() {
        guard canUseNotificationCenter else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            NSLog("AEMMonitor: requestAuthorization granted=\(granted) error=\(String(describing: error))")
            Task { @MainActor in
                if let error {
                    self.lastNotificationError = "Permission request failed: \(error.localizedDescription)"
                }
                self.refreshNotificationAuthorization()
            }
        }
    }

    func refreshNotificationAuthorization() {
        guard canUseNotificationCenter else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let status = s.authorizationStatus
            let style = s.alertStyle
            NSLog("AEMMonitor: notification authorization=\(status.rawValue) alertStyle=\(style.rawValue)")
            Task { @MainActor in
                self.notificationAuthorization = status
                self.notificationAlertStyle = style
            }
        }
    }

    /// Fires a sample notification so the user can confirm banners appear.
    /// If permission was never decided, asks first.
    func sendTestNotification() {
        lastNotificationError = nil
        if canUseNotificationCenter && notificationAuthorization == .notDetermined {
            requestNotificationPermission()
        }
        deliver(title: "AEM Monitor",
                body: "Test notification. Status changes will appear like this.",
                threadId: "aem-monitor-test",
                url: nil,
                sound: config.notifications.sound)
    }

    private func sendNotification(env: AEMEnvironment, programName: String,
                                  from previous: EnvironmentStatus?, to current: EnvironmentStatus,
                                  settings: NotificationSettings) {
        guard settings.enabled else { return }

        let title: String
        switch current {
        case .up:         title = "AEM Environment Ready"
        case .starting:   title = "AEM Environment Starting"
        case .hibernated: title = "AEM Environment Hibernated"
        case .down:       title = "AEM Environment Down"
        default:          title = "AEM Environment \(current.label)"
        }

        let location = "\(programName)/\(env.name) (\(env.envId))"
        let body: String
        if let previous {
            body = "\(location): \(previous.label) \u{2192} \(current.label)"
        } else {
            body = "\(location) is \(current.label.lowercased())"   // first poll, e.g. already up
        }

        deliver(title: title, body: body, threadId: env.id,
                url: env.authorURL, sound: settings.sound)
    }

    private func deliver(title: String, body: String, threadId: String, url: URL?, sound: Bool) {
        // Fallback: use NSSound + NSLog if no bundle identifier (swift run)
        guard canUseNotificationCenter else {
            if sound { NSSound(named: "Purr")?.play() }
            NSLog("\(title): \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = threadId          // groups per environment
        if sound { content.sound = .default }
        if let url { content.userInfo = ["url": url.absoluteString] }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            NSLog("AEMMonitor: deliver '\(title)' error=\(String(describing: error))")
            Task { @MainActor in
                if let error {
                    self.lastNotificationError = "Delivery failed: \(error.localizedDescription)"
                } else {
                    self.lastNotificationSent = Date()
                }
                self.refreshNotificationAuthorization()
            }
        }
    }
}
