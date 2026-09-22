import Foundation

/// Performs the HTTP check against an AEM author login page and determines status.
enum EnvironmentChecker {

    /// Check a single environment URL.
    /// - Returns the resolved `EnvironmentStatus`.
    static func check(url: URL) async -> EnvironmentStatus {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                return .error("Non-HTTP response")
            }

            guard http.statusCode == 200 else {
                return .down
            }

            // Body inspection — the critical check.
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.range(of: "hibernat", options: .caseInsensitive) != nil {
                return .hibernated
            }

            // A "restarting" environment serves a minimal login page
            // without the full Coral UI form. The actual login form
            // (with class="coral-Form") only appears once AEM is
            // fully started and ready to accept logins.
            if body.range(of: "coral-Form", options: .caseInsensitive) == nil {
                return .hibernated  // treat "restarting" as still not ready
            }

            return .up

        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return .error("Timeout")
            case .notConnectedToInternet, .networkConnectionLost:
                return .error("No network")
            case .cannotFindHost, .cannotConnectToHost:
                return .down
            default:
                return .error(error.localizedDescription)
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
