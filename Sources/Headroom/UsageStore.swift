import Combine
import Foundation
import HeadroomCore

/// Polls one provider: its own loop, backoff and error state.
@MainActor
final class ProviderStore: ObservableObject, Identifiable {
    enum Status: Equatable {
        case idle
        case loading
        case ok
        /// The provider's CLI isn't signed in on this Mac.
        case signedOut(String)
        case error(String)
    }

    let provider: UsageProvider
    /// Distinguishes several stores for the same provider (Claude accounts).
    /// Empty for providers that only ever have one, like Codex.
    let accountID: String
    /// "Claude", "Personal", "Acme Corp": shown in the UI and notifications.
    let label: String
    nonisolated var id: String { "\(provider.rawValue).\(accountID)" }

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var status: Status = .idle

    /// Called with every successful snapshot (threshold checks).
    var onSnapshot: ((UsageSnapshot) -> Void)?

    private let fetcher: UsageFetcher
    private var pollTask: Task<Void, Never>?
    /// Set after a 429 so neither the poll loop nor the Refresh button hammers the endpoint.
    private var rateLimitedUntil: Date?

    init(fetcher: UsageFetcher, accountID: String = "", label: String? = nil) {
        self.provider = fetcher.provider
        self.fetcher = fetcher
        self.accountID = accountID
        self.label = label ?? fetcher.provider.displayName
    }

    var isRunning: Bool { pollTask != nil }

    /// (Re)starts the poll loop, fetching immediately.
    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.refresh() else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        status = .idle
    }

    /// Refreshes when a popover opens, unless data is fresh.
    func refreshIfStale() {
        guard isRunning, status != .loading else { return }
        if let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < 120 { return }
        start()
    }

    /// Fetches once and returns the delay before the next fetch.
    private func refresh() async -> TimeInterval {
        let interval = AppSettings.refreshInterval
        if let until = rateLimitedUntil, until > Date() {
            status = .error(rateLimitMessage(until: until))
            return until.timeIntervalSinceNow
        }

        status = .loading
        do {
            let snapshot = try await fetcher.fetch()
            // Stopped or restarted mid-request: the newer loop owns the state.
            if Task.isCancelled { return interval }
            self.snapshot = snapshot
            status = .ok
            onSnapshot?(snapshot)
            return interval
        } catch UsageAPIError.rateLimited(_, let retryAfter) {
            let wait = min(max(retryAfter ?? 0, interval * 2, 120), 3600)
            let until = Date().addingTimeInterval(wait)
            rateLimitedUntil = until
            status = .error(rateLimitMessage(until: until))
            return wait
        } catch {
            if Task.isCancelled { return interval }
            status = Self.isSignedOut(error) ? .signedOut(error.localizedDescription) : .error(error.localizedDescription)
            return interval
        }
    }

    private static func isSignedOut(_ error: Error) -> Bool {
        (error as? ClaudeCredentialsError) == .notFound || (error as? CodexCredentialsError) == .notFound
    }

    private func rateLimitMessage(until: Date) -> String {
        "Rate limited by \(provider.vendor) — retrying in \(UsageFormatting.countdown(to: until))."
    }
}

extension Sequence where Element == ProviderStore {
    /// The store whose snapshot is closest to a limit. Ties go to the earlier
    /// element, so the menu bar doesn't flip between accounts at equal usage.
    func mostConstrained() -> ProviderStore? {
        var best: ProviderStore?
        for store in self {
            guard let peak = store.snapshot?.peakUtilization else { continue }
            if let currentPeak = best?.snapshot?.peakUtilization, currentPeak >= peak { continue }
            best = store
        }
        return best
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var providers: [ProviderStore] = []
    let notifier = NotificationManager()
    private let evaluator = ThresholdEvaluator()
    private var forwarding: [AnyCancellable] = []

    init() {
        notifier.requestAuthorization()
        rebuild(claudeAccounts: AppSettings.claudeAccounts, codex: ProviderStore(fetcher: CodexUsageClient()))
        applyEnabledProviders()
    }

    /// Replaces the Claude stores with one per configured account, keeping
    /// their poll loops running if they were. Codex is untouched.
    func updateClaudeAccounts(_ accounts: [ClaudeAccountConfig]) {
        AppSettings.claudeAccounts = accounts
        let codex = providers.first { $0.provider == .codex } ?? ProviderStore(fetcher: CodexUsageClient())
        providers.filter { $0.provider == .claude }.forEach { $0.stop() }
        // Re-read rather than reuse `accounts`: the setter sanitizes (e.g. a
        // blank label), and stores should reflect what got persisted.
        rebuild(claudeAccounts: AppSettings.claudeAccounts, codex: codex)
        applyEnabledProviders()
    }

    private func rebuild(claudeAccounts: [ClaudeAccountConfig], codex: ProviderStore) {
        forwarding = []
        let claudeStores = claudeAccounts.map { account in
            ProviderStore(fetcher: ClaudeUsageClient(credentials: ClaudeCredentials.loader(account: account)),
                          accountID: account.id, label: account.label)
        }
        providers = claudeStores + [codex]
        for store in providers {
            let accountID = store.accountID
            store.onSnapshot = { [weak self] in self?.checkThresholds($0, accountID: accountID) }
            // The combined menu bar icon depends on every provider.
            forwarding.append(store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        }
    }

    func stores(for provider: UsageProvider) -> [ProviderStore] {
        providers.filter { $0.provider == provider }
    }

    var enabledStores: [ProviderStore] {
        providers.filter { AppSettings.isEnabled($0.provider) }
    }

    /// Starts newly enabled providers and stops disabled ones.
    func applyEnabledProviders() {
        objectWillChange.send()
        for store in providers {
            let enabled = AppSettings.isEnabled(store.provider)
            if enabled, !store.isRunning {
                store.start()
            } else if !enabled, store.isRunning {
                store.stop()
            }
        }
    }

    /// Restarts every enabled provider's loop (Refresh button, interval change).
    func refreshAll() {
        enabledStores.forEach { $0.start() }
    }

    /// The enabled store closest to one of its limits, for the combined icon.
    var mostConstrained: ProviderStore? {
        let enabled = enabledStores
        return enabled.mostConstrained() ?? enabled.first
    }

    private func checkThresholds(_ snapshot: UsageSnapshot, accountID: String) {
        var state = AppSettings.thresholdState(for: snapshot.provider, accountID: accountID)
        let alerts = evaluator.evaluate(snapshot: snapshot, thresholds: AppSettings.thresholds, state: &state)
        AppSettings.setThresholdState(state, for: snapshot.provider, accountID: accountID)
        guard AppSettings.notificationsEnabled else { return }
        let label = providers.first { $0.provider == snapshot.provider && $0.accountID == accountID }?.label
        alerts.forEach { notifier.post($0, accountID: accountID, accountLabel: label) }
    }
}
