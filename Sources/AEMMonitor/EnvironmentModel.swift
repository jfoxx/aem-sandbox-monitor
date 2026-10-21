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

    /// Pipelines per program id (Cloud Manager API programs only).
    @Published var pipelines: [String: [PipelineRuntime]] = [:]
    @Published var pipelineLoadError: [String: String] = [:]
    @Published var pipelinesLoading: Set<String> = []

    /// Result of the last "Test" per account id, shown in Settings.
    @Published var accountTestResult: [String: String] = [:]
    /// Programs the account can see, offered for adding in Settings.
    @Published var accountPrograms: [String: [CMProgram]] = [:]
    @Published var accountBusy: Set<String> = []

    // MARK: - Internals

    private let pollInterval: TimeInterval = 30
    private var timers: [String: Timer] = [:]          // env composite id → Timer
    private var countdownTimers: [String: Timer] = [:]  // env composite id → 1-sec ticker

    /// Last *settled* status per watched environment (never .checking or
    /// .error). Used to detect transitions; cleared when a watch stops so a
    /// new watch starts from a fresh baseline.
    private var lastSettled: [String: EnvironmentStatus] = [:]

    private var pipelineTimers: [String: Timer] = [:]          // PipelineRuntime.id → Timer
    /// Last execution seen per watched pipeline; nil entry = never ran.
    private var lastExecution: [String: CMExecution?] = [:]

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

    var anyPipelineWatching: Bool { !pipelineTimers.isEmpty }

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

    // MARK: - Cloud Manager accounts

    func account(withId id: String?) -> CloudManagerAccount? {
        guard let id else { return nil }
        return config.accounts.first(where: { $0.id == id })
    }

    func account(forProgramId programId: String) -> CloudManagerAccount? {
        account(withId: config.programs.first(where: { $0.id == programId })?.accountId)
    }

    func usesCloudManager(programId: String) -> Bool {
        account(forProgramId: programId) != nil
    }

    func hasSecret(_ accountId: String) -> Bool {
        KeychainStore.hasSecret(for: accountId)
    }

    /// Adds or updates an account. An empty secret keeps the stored one.
    func saveAccount(_ account: CloudManagerAccount, secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            KeychainStore.setSecret(trimmed, for: account.id)
        }
        if let i = config.accounts.firstIndex(where: { $0.id == account.id }) {
            config.accounts[i] = account
        } else {
            config.accounts.append(account)
        }
        ConfigStore.save(config)
        Task { await IMSTokenProvider.shared.invalidate(account.id) }
        accountTestResult[account.id] = nil
    }

    func removeAccount(_ accountId: String) {
        for pi in config.programs.indices where config.programs[pi].accountId == accountId {
            stopAllInProgram(pi)
            stopPipelineWatches(programId: config.programs[pi].id)
            config.programs[pi].accountId = nil
        }
        config.accounts.removeAll { $0.id == accountId }
        KeychainStore.deleteSecret(for: accountId)
        ConfigStore.save(config)
        rebuildPrograms()
        accountTestResult[accountId] = nil
        accountPrograms[accountId] = nil
    }

    /// Switches a program between the login-page check (nil) and an account.
    func setAccount(_ accountId: String?, forProgramAt pi: Int) {
        guard config.programs.indices.contains(pi) else { return }
        stopAllInProgram(pi)
        let programId = config.programs[pi].id
        stopPipelineWatches(programId: programId)
        pipelines[programId] = nil
        pipelineLoadError[programId] = nil
        config.programs[pi].accountId = accountId
        ConfigStore.save(config)
        rebuildPrograms()
        if accountId != nil { refreshProgramDetails(programId: programId) }
    }

    /// Settings > Test: gets a token, lists programs, checks Restarting detection.
    func testAccount(_ accountId: String) {
        guard let account = self.account(withId: accountId) else { return }
        accountBusy.insert(accountId)
        accountTestResult[accountId] = "Testing…"
        Task {
            let client = CloudManagerClient(account: account)
            do {
                let programs = try await client.programs()
                self.accountPrograms[accountId] = programs
                var lines = ["OK: token issued, \(programs.count) program(s) visible"]
                if let first = programs.first(where: { p in self.config.programs.contains(where: { $0.id == p.id }) }) ?? programs.first {
                    lines.append(await client.restartDetectionCheck(programId: first.id))
                }
                self.accountTestResult[accountId] = lines.joined(separator: "\n")
            } catch {
                self.accountTestResult[accountId] = "Failed: \(error.localizedDescription)"
            }
            self.accountBusy.remove(accountId)
        }
    }

    /// Adds a program (and all its environments) from the API, or links an
    /// existing program with the same id to this account.
    func importProgram(_ program: CMProgram, accountId: String) {
        guard let account = self.account(withId: accountId) else { return }
        accountBusy.insert(accountId)
        Task {
            let client = CloudManagerClient(account: account)
            do {
                let envs = try await client.environments(programId: program.id)
                let envConfigs = envs
                    .filter { $0.type != "rde" }
                    .sorted { Self.envOrder($0.type) < Self.envOrder($1.type) }
                    .map { EnvironmentConfig(id: $0.id, name: $0.type.isEmpty ? $0.name : $0.type) }
                if let pi = self.config.programs.firstIndex(where: { $0.id == program.id }) {
                    self.stopAllInProgram(pi)
                    self.config.programs[pi].accountId = accountId
                    self.config.programs[pi].tenantId = program.tenantId
                    let known = Set(self.config.programs[pi].environments.map(\.id))
                    self.config.programs[pi].environments += envConfigs.filter { !known.contains($0.id) }
                } else {
                    self.config.programs.append(ProgramConfig(id: program.id, name: program.name,
                                                              environments: envConfigs,
                                                              accountId: accountId,
                                                              tenantId: program.tenantId))
                }
                ConfigStore.save(self.config)
                self.rebuildPrograms()
                self.accountTestResult[accountId] = "Added \(program.name) with \(envConfigs.count) environment(s)"
            } catch {
                self.accountTestResult[accountId] = "Could not add \(program.name): \(error.localizedDescription)"
            }
            self.accountBusy.remove(accountId)
        }
    }

    private static func envOrder(_ type: String) -> Int {
        ["dev": 0, "stage": 1, "prod": 2, "preprod": 3][type] ?? 9
    }

    /// Fetches the program's tenant id (for Cloud Manager deep links) once.
    private func refreshProgramDetails(programId: String) {
        guard let account = self.account(forProgramId: programId),
              let pi = config.programs.firstIndex(where: { $0.id == programId }),
              config.programs[pi].tenantId == nil else { return }
        Task {
            if let p = try? await CloudManagerClient(account: account).program(id: programId),
               let i = self.config.programs.firstIndex(where: { $0.id == programId }) {
                self.config.programs[i].tenantId = p.tenantId
                ConfigStore.save(self.config)
                self.rebuildPrograms()
            }
        }
    }

    // MARK: - Pipelines

    func loadPipelinesIfNeeded(programId: String) {
        guard usesCloudManager(programId: programId),
              pipelines[programId] == nil,
              !pipelinesLoading.contains(programId) else { return }
        refreshPipelines(programId: programId)
    }

    func refreshPipelines(programId: String) {
        guard let account = self.account(forProgramId: programId) else { return }
        pipelinesLoading.insert(programId)
        refreshProgramDetails(programId: programId)
        Task {
            let client = CloudManagerClient(account: account)
            do {
                let list = try await client.pipelines(programId: programId)
                let existing = Dictionary((self.pipelines[programId] ?? []).map { ($0.pipelineId, $0) }, uniquingKeysWith: { a, _ in a })
                var runtimes: [PipelineRuntime] = []
                for p in list {
                    var r = existing[p.id] ?? PipelineRuntime(programId: programId, pipelineId: p.id,
                                                              name: p.name, pipelineStatus: p.status)
                    r.name = p.name
                    r.pipelineStatus = p.status
                    r.isWatching = self.pipelineTimers[r.id] != nil
                    runtimes.append(r)
                }
                self.pipelines[programId] = runtimes
                self.pipelineLoadError[programId] = nil
                // Fill in each pipeline's latest run once, for the summary line.
                for r in runtimes where r.execution == nil && !r.isWatching {
                    if let e = try? await client.latestExecution(programId: programId, pipelineId: r.pipelineId) {
                        self.updatePipeline(programId: programId, pipelineId: r.pipelineId) { $0.execution = e }
                    }
                }
            } catch {
                self.pipelineLoadError[programId] = error.localizedDescription
            }
            self.pipelinesLoading.remove(programId)
        }
    }

    func startWatchingPipeline(programId: String, pipelineId: String) {
        let key = "\(programId)-\(pipelineId)"
        guard pipelineTimers[key] == nil else { return }
        updatePipeline(programId: programId, pipelineId: pipelineId) { $0.isWatching = true }
        pollPipeline(programId: programId, pipelineId: pipelineId)
        pipelineTimers[key] = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPipeline(programId: programId, pipelineId: pipelineId) }
        }
    }

    func stopWatchingPipeline(programId: String, pipelineId: String) {
        let key = "\(programId)-\(pipelineId)"
        pipelineTimers[key]?.invalidate()
        pipelineTimers.removeValue(forKey: key)
        lastExecution.removeValue(forKey: key)
        updatePipeline(programId: programId, pipelineId: pipelineId) { $0.isWatching = false }
    }

    private func stopPipelineWatches(programId: String) {
        for r in pipelines[programId] ?? [] where pipelineTimers[r.id] != nil {
            stopWatchingPipeline(programId: programId, pipelineId: r.pipelineId)
        }
    }

    private func updatePipeline(programId: String, pipelineId: String, _ change: (inout PipelineRuntime) -> Void) {
        guard var list = pipelines[programId],
              let i = list.firstIndex(where: { $0.pipelineId == pipelineId }) else { return }
        change(&list[i])
        pipelines[programId] = list
    }

    private func pollPipeline(programId: String, pipelineId: String) {
        guard let account = self.account(forProgramId: programId) else {
            stopWatchingPipeline(programId: programId, pipelineId: pipelineId)
            return
        }
        let key = "\(programId)-\(pipelineId)"
        Task {
            let result: CMExecution?
            do {
                result = try await CloudManagerClient(account: account)
                    .latestExecution(programId: programId, pipelineId: pipelineId)
            } catch {
                // Transient: shown inline, never notifies, baseline unchanged.
                self.updatePipeline(programId: programId, pipelineId: pipelineId) {
                    $0.error = error.localizedDescription
                    $0.lastCheck = Date()
                }
                return
            }
            guard self.pipelineTimers[key] != nil else { return }   // stopped meanwhile

            let isFirstPoll = self.lastExecution[key] == nil
            let previous: CMExecution? = self.lastExecution[key] ?? nil
            self.lastExecution[key] = .some(result)
            self.updatePipeline(programId: programId, pipelineId: pipelineId) {
                $0.execution = result
                $0.error = nil
                $0.lastCheck = Date()
            }
            guard let current = result else { return }

            let name = self.pipelines[programId]?.first(where: { $0.pipelineId == pipelineId })?.name ?? pipelineId
            let programName = self.config.programs.first(where: { $0.id == programId })?.name ?? programId
            let url = self.executionURL(programId: programId, pipelineId: pipelineId, executionId: current.id)
            let settings = self.config.notifications
            let location = "\(programName) / \(name)"
            let sameRun = previous?.id == current.id
            let waiting = current.steps.first(where: { $0.status == "WAITING" })
            let previousWaiting: CMStep? = sameRun ? previous?.steps.first(where: { $0.status == "WAITING" }) : nil

            if isFirstPoll {
                // Baseline only, except a run that is already waiting on someone.
                if let waiting, !current.isTerminal {
                    self.sendPipelineNotification(title: "Pipeline Waiting",
                                                  body: "\(location): \(waiting.displayName) needs action",
                                                  threadId: key, url: url, settings: settings)
                }
                return
            }

            if !sameRun {
                if current.isTerminal {
                    // A whole run happened between polls.
                    self.notifyPipelineResult(current, location: location, threadId: key, url: url, settings: settings)
                    self.finishPipelineWatchIfNeeded(programId: programId, pipelineId: pipelineId, settings: settings)
                } else {
                    self.sendPipelineNotification(title: "Pipeline Started",
                                                  body: "\(location): \(current.summary)",
                                                  threadId: key, url: url, settings: settings)
                }
                return
            }

            guard let previous, previous != current else { return }

            if current.isTerminal && !previous.isTerminal {
                self.notifyPipelineResult(current, location: location, threadId: key, url: url, settings: settings)
                self.finishPipelineWatchIfNeeded(programId: programId, pipelineId: pipelineId, settings: settings)
                return
            }
            if let waiting, waiting.key != previousWaiting?.key {
                self.sendPipelineNotification(title: "Pipeline Waiting",
                                              body: "\(location): \(waiting.displayName) needs action",
                                              threadId: key, url: url, settings: settings)
                return
            }
            if settings.pipelineSteps,
               let active = current.activeStep, active.status == "RUNNING",
               active.key != previous.activeStep?.key {
                self.sendPipelineNotification(title: "Pipeline Step",
                                              body: "\(location): \(active.displayName)",
                                              threadId: key, url: url, settings: settings)
            }
        }
    }

    private func notifyPipelineResult(_ e: CMExecution, location: String, threadId: String,
                                      url: URL?, settings: NotificationSettings) {
        let title: String
        switch e.status {
        case "FINISHED":  title = "Pipeline Succeeded"
        case "CANCELLED": title = "Pipeline Cancelled"
        default:          title = "Pipeline Failed"
        }
        var body = "\(location): \(e.summary)"
        if let start = e.createdAt, let end = e.finishedAt {
            let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
            body += " after \(minutes) min"
        }
        sendPipelineNotification(title: title, body: body, threadId: threadId, url: url, settings: settings)
        if e.status == "FINISHED" { onEnvironmentWokeUp?() }
    }

    private func finishPipelineWatchIfNeeded(programId: String, pipelineId: String, settings: NotificationSettings) {
        if !settings.keepWatchingWhenUp {
            stopWatchingPipeline(programId: programId, pipelineId: pipelineId)
        }
    }

    private func sendPipelineNotification(title: String, body: String, threadId: String,
                                          url: URL?, settings: NotificationSettings) {
        guard settings.enabled else { return }
        deliver(title: title, body: body, threadId: threadId, url: url, sound: settings.sound)
    }

    /// Deep link to the execution in Cloud Manager.
    func executionURL(programId: String, pipelineId: String, executionId: String) -> URL? {
        let path = "cloud-manager/pipelineexecution.html/program/\(programId)/pipeline/\(pipelineId)/execution/\(executionId)"
        return cloudManagerURL(programId: programId, path: path)
    }

    func cloudManagerURL(programId: String, path: String? = nil) -> URL? {
        let p = path ?? "cloud-manager/home.html/program/\(programId)"
        if let tenant = config.programs.first(where: { $0.id == programId })?.tenantId, !tenant.isEmpty {
            return URL(string: "https://experience.adobe.com/#/@\(tenant)/\(p)")
        }
        return URL(string: "https://experience.adobe.com/#/\(p)")
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
        for (programId, list) in pipelines {
            for p in list where p.isWatching {
                stopWatchingPipeline(programId: programId, pipelineId: p.pipelineId)
            }
        }
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
        let account = self.account(forProgramId: env.programId)
        programs[pi].environments[ei].status = .checking
        Task {
            let result: EnvironmentStatus
            if let account {
                // Same status Cloud Manager shows, including "Restarting".
                do {
                    result = try await CloudManagerClient(account: account)
                        .environmentStatus(programId: env.programId, envId: env.envId)
                } catch {
                    result = .error(error.localizedDescription)
                }
            } else {
                result = await EnvironmentChecker.check(url: env.url)
            }
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
        case .starting:   title = "AEM Environment Restarting"
        case .hibernated: title = "AEM Environment Hibernated"
        case .updating:   title = "AEM Environment Updating"
        case .failed:     title = "AEM Environment Problem"
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
