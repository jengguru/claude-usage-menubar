import AppKit
import SwiftUI
import HeadroomCore

extension UsageProvider {
    var websiteTitle: String {
        switch self {
        case .claude: return "Open Claude.ai"
        case .codex: return "Open Codex usage"
        }
    }

    var websiteURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai")!
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        }
    }
}

struct PopoverView: View {
    /// `nil`: every enabled provider (the combined icon). Otherwise that provider's own icon.
    let scope: UsageProvider?

    @EnvironmentObject private var store: UsageStore
    @State private var showingSettings = false

    private var shownStores: [ProviderStore] {
        if let scope { return store.stores(for: scope) }
        return store.enabledStores
    }

    var body: some View {
        let shown = shownStores
        VStack(spacing: 0) {
            header(shown)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            if showingSettings {
                SettingsPanel(done: { showingSettings = false })
                    .environmentObject(store)
            } else {
                content(shown)
                Divider()
                actions(shown).padding(16)
            }
        }
        .frame(width: 320)
        .onAppear { shown.forEach { $0.refreshIfStale() } }
    }

    private func header(_ shown: [ProviderStore]) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 1) {
                Text("Headroom").font(.headline.weight(.bold))
                Text(subtitle(shown)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: showingSettings ? "xmark.circle" : "gearshape")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(showingSettings ? "Close settings" : "Settings")
        }
    }

    private func subtitle(_ shown: [ProviderStore]) -> String {
        guard shown.count == 1, let only = shown.first else {
            return shown.isEmpty ? "No services turned on" : shown.map(\.label).joined(separator: " & ") + " usage"
        }
        return only.planDescription ?? "\(only.label) usage"
    }

    @ViewBuilder
    private func content(_ shown: [ProviderStore]) -> some View {
        VStack(spacing: shown.count > 1 ? 16 : 12) {
            if shown.isEmpty {
                MessageCard(icon: "switch.2", text: "Turn on Claude or Codex in Settings.")
            }
            ForEach(shown) { provider in
                ProviderSection(provider: provider, isOnlyProvider: shown.count == 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func actions(_ shown: [ProviderStore]) -> some View {
        VStack(spacing: 8) {
            if shown.count == 1, let only = shown.first?.provider {
                Button {
                    NSWorkspace.shared.open(only.websiteURL)
                } label: {
                    Label(only.websiteTitle, systemImage: "arrow.up.right")
                        .labelStyle(TrailingIconLabelStyle())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            HStack(spacing: 8) {
                Button { shown.forEach { $0.start() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .keyboardShortcut("r")
                .disabled(shown.isEmpty || shown.allSatisfy { $0.status == .loading })
                Button { NSApp.terminate(nil) } label: {
                    Label("Quit", systemImage: "power").frame(maxWidth: .infinity)
                }
                .keyboardShortcut("q")
            }
            .controlSize(.large)
        }
    }
}

extension ProviderStore {
    /// "Claude Max plan", "Personal Max plan", "Codex Plus plan".
    var planDescription: String? {
        guard let plan = snapshot?.plan, !plan.isEmpty else { return nil }
        return "\(label) \(plan.capitalized) plan"
    }
}

/// One provider's cards. With several providers each gets a heading and
/// smaller cards so the popover stays a reasonable height.
private struct ProviderSection: View {
    @ObservedObject var provider: ProviderStore
    let isOnlyProvider: Bool

    var body: some View {
        VStack(spacing: isOnlyProvider ? 12 : 8) {
            if !isOnlyProvider { heading }
            cards
            if provider.provider == .codex {
                Text("Shows Codex limits only. ChatGPT chat message limits aren't available.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            StatusLine(provider: provider)
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(provider.label).font(.subheadline.weight(.bold))
            if let plan = provider.snapshot?.plan, !plan.isEmpty {
                Text("\(plan.capitalized) plan").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(provider.provider.websiteURL)
            } label: {
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(provider.provider.websiteTitle)
        }
    }

    @ViewBuilder
    private var cards: some View {
        if let snapshot = provider.snapshot {
            let primary = snapshot.windows.filter(\.isPrimary)
            if snapshot.windows.isEmpty {
                MessageCard(icon: "info.circle", text: "Your plan reports no \(provider.label) usage limits.")
            }
            ForEach(primary, id: \.id) { window in
                UsageCard(window: window, icon: window.category == .session ? "clock.badge.checkmark" : "calendar.badge.clock",
                          compact: !isOnlyProvider)
            }
            ForEach(snapshot.extraWindows, id: \.id) { window in
                CompactUsageRow(window: window)
            }
        } else {
            switch provider.status {
            case .signedOut(let message):
                MessageCard(icon: "person.crop.circle.badge.questionmark",
                            text: message + "\n\nNot using \(provider.label)? Turn it off in Settings.")
            case .error(let message):
                MessageCard(icon: "exclamationmark.triangle", text: message)
            case .idle, .loading, .ok:
                ProgressView().padding(isOnlyProvider ? 32 : 12)
            }
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: max(geometry.size.width * fraction, fraction > 0 ? 6 : 0))
            }
        }
        .frame(height: 6)
    }
}

private struct UsageCard: View {
    let window: UsageWindow
    let icon: String
    var compact = false

    var body: some View {
        if compact {
            compactBody
        } else {
            fullBody
        }
    }

    /// Title, percentage and reset countdown on two lines, for the multi-provider popover.
    private var compactBody: some View {
        let level = UsageLevel(utilization: window.utilization)
        return Card {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Label(window.title, systemImage: icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(UsageFormatting.percent(window.utilization))%")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(level == .normal ? Color.primary : level.color)
                        .monospacedDigit()
                }
                UsageBar(fraction: window.fraction, color: level.color)
                ResetText(resetsAt: window.resetsAt, compact: true)
            }
        }
    }

    private var fullBody: some View {
        let level = UsageLevel(utilization: window.utilization)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(window.title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(UsageFormatting.percent(window.utilization))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    Text("%").font(.system(size: 18, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("\(UsageFormatting.percent(window.remainingPercent))% left")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(level == .normal ? Color.primary : level.color)
                .monospacedDigit()

                UsageBar(fraction: window.fraction, color: level.color)

                ResetText(resetsAt: window.resetsAt)
            }
        }
    }
}

private struct CompactUsageRow: View {
    let window: UsageWindow

    var body: some View {
        let level = UsageLevel(utilization: window.utilization)
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(window.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(UsageFormatting.percent(window.utilization))%")
                        .font(.caption.weight(.bold)).monospacedDigit()
                        .foregroundStyle(level == .normal ? Color.primary : level.color)
                }
                UsageBar(fraction: window.fraction, color: level.color)
            }
        }
    }
}

private struct ResetText: View {
    let resetsAt: Date?
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 3) {
                if compact {
                    Text(compactText(now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let resetsAt {
                    Text("Resets in: \(UsageFormatting.countdown(to: resetsAt, now: context.date))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(UsageFormatting.resetDescription(resetsAt, now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not started — no usage in this window yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension ResetText {
    func compactText(now: Date) -> String {
        guard let resetsAt else { return "Not started — no usage yet" }
        return "Resets in \(UsageFormatting.countdown(to: resetsAt, now: now)) · \(UsageFormatting.resetDescription(resetsAt, now: now))"
    }
}

private struct MessageCard: View {
    let icon: String
    let text: String

    var body: some View {
        Card {
            Label {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: icon).foregroundStyle(.orange)
            }
        }
    }
}

private struct StatusLine: View {
    @ObservedObject var provider: ProviderStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(dotColor).frame(width: 6, height: 6)
                Text(text(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var dotColor: Color {
        switch provider.status {
        case .error, .signedOut: return .orange
        case .loading: return .blue
        default: return .green
        }
    }

    private func text(now: Date) -> String {
        switch provider.status {
        case .loading:
            return "Updating…"
        case .error(let message) where provider.snapshot != nil, .signedOut(let message) where provider.snapshot != nil:
            // Keep showing the last good data; explain why it's stale.
            let age = provider.snapshot.map { UsageFormatting.relativeAge(of: $0.fetchedAt, now: now) } ?? ""
            return "Updated \(age) · \(message)"
        case .error, .signedOut:
            return "Not updated"
        case .idle, .ok:
            guard let snapshot = provider.snapshot else { return "Waiting for data" }
            return "Updated \(UsageFormatting.relativeAge(of: snapshot.fetchedAt, now: now))"
        }
    }
}
