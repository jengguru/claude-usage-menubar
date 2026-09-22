import Foundation
import ClaudeMeterCore

@MainActor
final class UsageStore: ObservableObject {
    enum Status: Equatable {
        case idle
        case loading
        case ok
        case error(String)
    }

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var status: Status = .idle
    @Published private(set) var subscriptionType: String?

    let notifier = NotificationManager()
    private let client = UsageAPIClient()
    private let credentials = CompositeCredentialsSource.standard
    private let evaluator = ThresholdEvaluator()
    private var pollTask: Task<Void, Never>?
    /// Set after a 429 so neither the poll loop nor the Refresh button hammers the endpoint.
    private var rateLimitedUntil: Date?

    init() {
        notifier.requestAuthorization()
        startPolling()
    }

    /// (Re)starts the poll loop, fetching immediately.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.refresh() else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func refreshNow() {
        startPolling()
    }

    /// Refreshes when the popover opens, unless data is fresh.
    func refreshIfStale() {
        guard status != .loading else { return }
        if let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < 120 { return }
        startPolling()
    }

    /// Fetches once and returns the delay before the next fetch.
    private func refresh() async -> TimeInterval {
        let interval = AppSettings.refreshInterval
        if let until = rateLimitedUntil, until > Date() {
            status = .error("Rate limited by Anthropic — retrying in \(UsageFormatting.countdown(to: until)).")
            return until.timeIntervalSinceNow
        }

        status = .loading
        var loaded: OAuthCredentials?
        do {
            let source = credentials
            // `security` can block on a Keychain prompt, so keep it off the main thread.
            let creds = try await Task.detached(priority: .utility) { try source.loadRequired() }.value
            loaded = creds
            subscriptionType = creds.subscriptionType
            let snapshot = try await client.fetch(accessToken: creds.accessToken)
            self.snapshot = snapshot
            status = .ok
            checkThresholds(snapshot)
            return interval
        } catch UsageAPIError.rateLimited(let retryAfter) {
            let wait = min(max(retryAfter ?? 0, interval * 2, 120), 3600)
            rateLimitedUntil = Date().addingTimeInterval(wait)
            status = .error("Rate limited by Anthropic — retrying in \(UsageFormatting.countdown(to: rateLimitedUntil!)).")
            return wait
        } catch UsageAPIError.unauthorized {
            let expired = loaded?.isExpired() ?? false
            status = .error(expired
                ? "Claude Code's sign-in token expired. Use Claude Code (or run `claude`) once to refresh it — this app picks it up automatically."
                : UsageAPIError.unauthorized.errorDescription ?? "Unauthorized.")
            return interval
        } catch {
            // A superseded fetch (Refresh pressed mid-request) must not clobber the new one's status.
            if Task.isCancelled { return interval }
            status = .error(error.localizedDescription)
            return interval
        }
    }

    private func checkThresholds(_ snapshot: UsageSnapshot) {
        var state = AppSettings.thresholdState
        let alerts = evaluator.evaluate(snapshot: snapshot, thresholds: AppSettings.thresholds, state: &state)
        AppSettings.thresholdState = state
        guard AppSettings.notificationsEnabled else { return }
        alerts.forEach(notifier.post)
    }
}
