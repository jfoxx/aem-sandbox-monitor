import Foundation
import Security

// MARK: - Keychain (client secrets never go in config.json)

enum KeychainStore {
    private static let service = "com.adobe.aem-monitor.cloudmanager"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    @discardableResult
    static func setSecret(_ secret: String, for account: String) -> Bool {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var add = baseQuery(account)
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrLabel as String] = "AEM Monitor: Cloud Manager client secret"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func secret(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasSecret(for account: String) -> Bool {
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func deleteSecret(for account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

// MARK: - Errors

enum CloudManagerError: LocalizedError {
    case missingSecret
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingSecret:
            return "No client secret in Keychain"
        case .http(let code, let message):
            switch code {
            case 401: return "401 Unauthorized" + (message.isEmpty ? "" : ": \(message)")
            case 403: return "403 Forbidden (check the credential's product profile)" + (message.isEmpty ? "" : ": \(message)")
            default:  return "HTTP \(code)" + (message.isEmpty ? "" : ": \(message)")
            }
        case .badResponse(let message):
            return message
        }
    }

    var statusCode: Int? {
        if case .http(let code, _) = self { return code }
        return nil
    }
}

// MARK: - IMS OAuth Server-to-Server token

/// Fetches and caches client_credentials access tokens per account.
/// The Keychain is only read when a token has to be (re)issued, roughly
/// once a day, not on every poll.
actor IMSTokenProvider {
    static let shared = IMSTokenProvider()

    private struct Cached {
        let token: String
        let expires: Date
    }

    private var cache: [String: Cached] = [:]
    private static let tokenURL = URL(string: "https://ims-na1.adobelogin.com/ims/token/v3")!

    func token(for account: CloudManagerAccount) async throws -> String {
        if let cached = cache[account.id], cached.expires > Date().addingTimeInterval(300) {
            return cached.token
        }
        guard let secret = KeychainStore.secret(for: account.id), !secret.isEmpty else {
            throw CloudManagerError.missingSecret
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let scopes = account.scopes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        request.httpBody = Self.formEncode([
            ("grant_type", "client_credentials"),
            ("client_id", account.clientId.trimmingCharacters(in: .whitespaces)),
            ("client_secret", secret),
            ("scope", scopes)
        ]).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        guard code == 200, let token = json["access_token"] as? String else {
            let message = (json["error_description"] as? String) ?? (json["error"] as? String) ?? ""
            throw CloudManagerError.http(code, "IMS token request failed" + (message.isEmpty ? "" : " (\(message))"))
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        cache[account.id] = Cached(token: token, expires: Date().addingTimeInterval(expiresIn))
        return token
    }

    func invalidate(_ accountId: String) {
        cache[accountId] = nil
    }

    private static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
    }
}

// MARK: - API value types

struct CMProgram: Identifiable, Hashable {
    let id: String
    let name: String
    let tenantId: String?
}

struct CMEnvironment: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let status: String
}

struct CMPipeline: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String          // IDLE / BUSY / WAITING
}

struct CMStep: Equatable {
    let action: String
    let status: String          // NOT_STARTED, RUNNING, WAITING, FINISHED, FAILED, ERROR, CANCELLED, ...
    let environmentType: String?

    /// Human name for the step, following Cloud Manager's own step names.
    var displayName: String {
        let base: String
        switch action {
        case "validate":              base = "Validation"
        case "build":                 base = "Build"
        case "codeQuality":           base = "Code Quality"
        case "buildImage":            base = "Build Image"
        case "securityTest":          base = "Security Testing"
        case "loadTest":              base = "Performance Testing"
        case "assetsTest":            base = "Assets Performance Testing"
        case "reportPerformanceTest": base = "Performance Report"
        case "productTest":           base = "Product Functional Testing"
        case "functionalTest":        base = "Custom Functional Testing"
        case "contentAudit":          base = "Experience Audit"
        case "approval":              base = "Go-Live Approval"
        case "schedule":              base = "Scheduled Deployment"
        case "managed":               base = "CSE Oversight"
        case "deploy":                base = "Deploy"
        default:                      base = action
        }
        if action == "deploy", let env = environmentType, !env.isEmpty {
            return "\(base) to \(env)"
        }
        return base
    }

    var key: String { "\(action)|\(environmentType ?? "")|\(status)" }
}

struct CMExecution: Equatable {
    let id: String
    let status: String          // NOT_STARTED, RUNNING, CANCELLING, CANCELLED, FINISHED, ERROR, FAILED
    let steps: [CMStep]
    let createdAt: Date?
    let finishedAt: Date?

    static let terminalStatuses: Set<String> = ["FINISHED", "FAILED", "ERROR", "CANCELLED"]

    var isTerminal: Bool { Self.terminalStatuses.contains(status) }

    /// The step currently running or waiting for a person, if any.
    var activeStep: CMStep? {
        steps.first(where: { $0.status == "WAITING" }) ?? steps.first(where: { $0.status == "RUNNING" })
    }

    var failedStep: CMStep? {
        steps.first(where: { $0.status == "FAILED" || $0.status == "ERROR" })
    }

    /// Short state text, e.g. "Running: Build", "Waiting: Go-Live Approval", "Failed: Deploy to dev".
    var summary: String {
        switch status {
        case "FINISHED":
            return "Succeeded"
        case "FAILED", "ERROR":
            if let step = failedStep { return "Failed: \(step.displayName)" }
            return "Failed"
        case "CANCELLED":
            return "Cancelled"
        case "CANCELLING":
            return "Cancelling"
        case "NOT_STARTED":
            return "Starting"
        default:
            if let step = activeStep {
                return step.status == "WAITING" ? "Waiting: \(step.displayName)" : "Running: \(step.displayName)"
            }
            return "Running"
        }
    }
}

// MARK: - Client

/// Read-only Cloud Manager API client (GET only). Works with a credential
/// that has the Cloud Manager "Developer" product profile.
struct CloudManagerClient {
    let account: CloudManagerAccount

    static let base = URL(string: "https://cloudmanager.adobe.io")!
    static let devConsoleStatusRel = "http://ns.adobe.com/adobecloud/rel/developerConsoleStatus"

    // MARK: Requests

    func getJSON(_ pathOrURL: String) async throws -> [String: Any] {
        let url: URL
        if pathOrURL.hasPrefix("http") {
            guard let u = URL(string: pathOrURL) else { throw CloudManagerError.badResponse("Bad URL \(pathOrURL)") }
            url = u
        } else {
            guard let u = URL(string: pathOrURL, relativeTo: Self.base) else { throw CloudManagerError.badResponse("Bad path \(pathOrURL)") }
            url = u.absoluteURL
        }

        let token = try await IMSTokenProvider.shared.token(for: account)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(account.clientId.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "x-api-key")
        request.setValue(account.orgId.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "x-gw-ims-org-id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            await IMSTokenProvider.shared.invalidate(account.id)
        }
        guard (200..<300).contains(code) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (json?["message"] as? String) ?? (json?["title"] as? String) ?? ""
            throw CloudManagerError.http(code, message)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudManagerError.badResponse("Unexpected response from \(url.path)")
        }
        return object
    }

    // MARK: Programs and environments

    func programs() async throws -> [CMProgram] {
        let list = try await getJSON("/api/programs")
        return Self.embedded(list, "programs").compactMap { p in
            guard let id = Self.string(p["id"]) else { return nil }
            return CMProgram(id: id,
                             name: Self.string(p["name"]) ?? id,
                             tenantId: Self.string(p["tenantId"]))
        }
    }

    func program(id: String) async throws -> CMProgram {
        let p = try await getJSON("/api/program/\(id)")
        return CMProgram(id: id, name: Self.string(p["name"]) ?? id, tenantId: Self.string(p["tenantId"]))
    }

    func environments(programId: String) async throws -> [CMEnvironment] {
        let list = try await getJSON("/api/program/\(programId)/environments")
        return Self.embedded(list, "environments").compactMap { e in
            guard let id = Self.string(e["id"]) else { return nil }
            return CMEnvironment(id: id,
                                 name: Self.string(e["name"]) ?? id,
                                 type: Self.string(e["type"]) ?? "",
                                 status: Self.string(e["status"]) ?? "")
        }
    }

    /// Status exactly as the Cloud Manager UI derives it: the environment's
    /// own status, overridden by the Developer Console state ("starting" is
    /// what the UI labels "Restarting") when the environment reports ready.
    func environmentStatus(programId: String, envId: String) async throws -> EnvironmentStatus {
        let env = try await getJSON("/api/program/\(programId)/environment/\(envId)")
        let status = (Self.string(env["status"]) ?? "").lowercased()
        var devConsoleState: String? = nil
        if status == "ready", let href = Self.link(env, Self.devConsoleStatusRel) {
            if let dc = try? await getJSON(href) {
                devConsoleState = Self.string(dc["state"])?.lowercased()
            }
        }
        let mapped = CloudManagerStatusMapper.map(status: status, devConsoleState: devConsoleState)
        // If the Developer Console state was unavailable, never report a
        // "ready" environment as Running while its author still shows the
        // hibernation or startup page.
        if status == "ready", devConsoleState == nil, mapped == .up,
           let url = URL(string: "https://author-p\(programId)-e\(envId).adobeaemcloud.com/libs/granite/core/content/login.html") {
            let page = await EnvironmentChecker.check(url: url)
            if page == .hibernated || page == .starting { return page }
        }
        return mapped
    }

    /// For Settings > Test: does this credential get the Developer Console
    /// status link that "Restarting" detection depends on?
    func restartDetectionCheck(programId: String) async -> String {
        do {
            let list = try await getJSON("/api/program/\(programId)/environments")
            let envs = Self.embedded(list, "environments")
            guard !envs.isEmpty else { return "no environments in program \(programId)" }
            var withLink = 0
            var sampleState: String? = nil
            for listed in envs {
                // The list may omit links, so read each environment itself.
                var e = listed
                if let id = Self.string(listed["id"]),
                   let full = try? await getJSON("/api/program/\(programId)/environment/\(id)") {
                    e = full
                }
                if let href = Self.link(e, Self.devConsoleStatusRel) {
                    withLink += 1
                    if sampleState == nil, let dc = try? await getJSON(href) {
                        sampleState = Self.string(dc["state"])
                    }
                }
            }
            if withLink == 0 {
                return "Restarting detection: NOT available (no developerConsoleStatus link returned)"
            }
            return "Restarting detection: available on \(withLink)/\(envs.count) env(s)"
                + (sampleState.map { ", sample state \"\($0)\"" } ?? "")
        } catch {
            return "Environment check failed: \(error.localizedDescription)"
        }
    }

    // MARK: Pipelines

    func pipelines(programId: String) async throws -> [CMPipeline] {
        let list = try await getJSON("/api/program/\(programId)/pipelines")
        return Self.embedded(list, "pipelines").compactMap { p in
            guard let id = Self.string(p["id"]) else { return nil }
            return CMPipeline(id: id,
                              name: Self.string(p["name"]) ?? id,
                              status: Self.string(p["status"]) ?? "")
        }
    }

    /// Most recent execution (running or finished), or nil if the pipeline has never run.
    func latestExecution(programId: String, pipelineId: String) async throws -> CMExecution? {
        do {
            let list = try await getJSON("/api/program/\(programId)/pipeline/\(pipelineId)/executions?start=0&limit=1")
            guard let e = Self.embedded(list, "executions").first else { return nil }
            return Self.parseExecution(e)
        } catch let error as CloudManagerError where error.statusCode == 404 {
            return nil
        }
    }

    // MARK: Parsing helpers

    static func parseExecution(_ e: [String: Any]) -> CMExecution? {
        guard let id = string(e["id"]) else { return nil }
        let steps = embedded(e, "stepStates").map { s in
            CMStep(action: string(s["action"]) ?? "",
                   status: string(s["status"]) ?? "",
                   environmentType: string(s["environmentType"]))
        }
        return CMExecution(id: id,
                           status: string(e["status"]) ?? "",
                           steps: steps,
                           createdAt: date(e["createdAt"]),
                           finishedAt: date(e["finishedAt"]))
    }

    static func embedded(_ object: [String: Any], _ key: String) -> [[String: Any]] {
        ((object["_embedded"] as? [String: Any])?[key] as? [[String: Any]]) ?? []
    }

    static func link(_ object: [String: Any], _ rel: String) -> String? {
        guard let links = object["_links"] as? [String: Any] else { return nil }
        if let single = links[rel] as? [String: Any] { return single["href"] as? String }
        if let many = links[rel] as? [[String: Any]] { return many.first?["href"] as? String }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}

// MARK: - Status mapping (mirrors the Cloud Manager UI)

enum CloudManagerStatusMapper {
    /// `status` is the API's environment status; `devConsoleState` is the
    /// Developer Console state (running / starting / hibernated / ingesting)
    /// that the Cloud Manager UI layers on top for ready environments.
    static func map(status: String, devConsoleState: String?) -> EnvironmentStatus {
        switch devConsoleState {
        case "starting":   return .starting
        case "hibernated": return .hibernated
        case "ingesting":  return .busy("Ingestion in progress")
        default:           break
        }
        switch status {
        case "ready":          return .up
        case "hibernated":     return .hibernated
        case "updating":       return .updating
        case "creating":       return .busy("Coming Up")
        case "created":        return .busy("Pending Deployment")
        case "deleting":       return .busy("Deleting")
        case "restoring":      return .busy("Restoring")
        case "resetting":      return .busy("Resetting")
        case "deleted":        return .failed("Deleted")
        case "failed":         return .failed("Failed")
        case "deploy_failed":  return .failed("Deployment Failed")
        case "restore_failed": return .failed("Restore Failed")
        case "reset_failed":   return .failed("Reset failed")
        case "degraded":       return .failed("Publish region unavailable")
        case "":               return .error("No status in response")
        default:               return .busy(status.replacingOccurrences(of: "_", with: " ").capitalized)
        }
    }
}
