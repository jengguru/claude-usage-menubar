import AppKit
import SwiftUI
import ClaudeMeterCore

struct PopoverView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            if showingSettings {
                SettingsPanel(done: { showingSettings = false })
                    .environmentObject(store)
            } else {
                content
                Divider()
                actions.padding(16)
            }
        }
        .frame(width: 320)
        .onAppear { store.refreshIfStale() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Meter").font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
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

    private var subtitle: String {
        guard let plan = store.subscriptionType, !plan.isEmpty else { return "Usage Overview" }
        return "\(plan.capitalized) plan"
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 12) {
            if let snapshot = store.snapshot {
                if let session = snapshot.session {
                    UsageCard(window: session, icon: "clock.badge.checkmark")
                }
                if let weekly = snapshot.weekly {
                    UsageCard(window: weekly, icon: "calendar.badge.clock")
                }
                ForEach(snapshot.extraWindows, id: \.kind) { window in
                    CompactUsageRow(window: window)
                }
            } else if case .error(let message) = store.status {
                MessageCard(icon: "exclamationmark.triangle", text: message)
            } else {
                ProgressView().padding(32)
            }
            StatusLine()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                NSWorkspace.shared.open(URL(string: "https://claude.ai")!)
            } label: {
                Label("Open Claude.ai", systemImage: "arrow.up.right")
                    .labelStyle(TrailingIconLabelStyle())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 8) {
                Button { store.refreshNow() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .keyboardShortcut("r")
                .disabled(store.status == .loading)
                Button { NSApp.terminate(nil) } label: {
                    Label("Quit", systemImage: "power").frame(maxWidth: .infinity)
                }
                .keyboardShortcut("q")
            }
            .controlSize(.large)
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

    var body: some View {
        let level = UsageLevel(utilization: window.utilization)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(window.kind.title, systemImage: icon)
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
                    Text(window.kind.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 3) {
                if let resetsAt {
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
    @EnvironmentObject private var store: UsageStore

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
        switch store.status {
        case .error: return .orange
        case .loading: return .blue
        default: return .green
        }
    }

    private func text(now: Date) -> String {
        switch store.status {
        case .loading:
            return "Updating…"
        case .error(let message) where store.snapshot != nil:
            // Keep showing the last good data; explain why it's stale.
            let age = store.snapshot.map { UsageFormatting.relativeAge(of: $0.fetchedAt, now: now) } ?? ""
            return "Updated \(age) · \(message)"
        case .error:
            return "Not updated"
        case .idle, .ok:
            guard let snapshot = store.snapshot else { return "Waiting for data" }
            return "Updated \(UsageFormatting.relativeAge(of: snapshot.fetchedAt, now: now))"
        }
    }
}
