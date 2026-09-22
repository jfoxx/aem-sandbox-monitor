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

    // MARK: - Internals

    private let pollInterval: TimeInterval = 30
    private var timers: [String: Timer] = [:]          // env composite id → Timer
    private var countdownTimers: [String: Timer] = [:]  // env composite id → 1-sec ticker

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

            if result == .up {
                let programName = programs[pi].name
                let envName = env.name
                stopWatching(programIndex: pi, envIndex: ei)
                sendNotification(program: programName, env: envName)
                onEnvironmentWokeUp?()
            }
        }
    }

    // MARK: - Notifications

    func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(program: String, env: String) {
        // Fallback: use NSSound + NSLog if no bundle identifier (swift run)
        guard Bundle.main.bundleIdentifier != nil else {
            NSSound(named: "Purr")?.play()
            NSLog("AEM Environment Ready: \(program)/\(env) is now awake")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "AEM Environment Ready"
        content.body = "\(program)/\(env) is now awake"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
