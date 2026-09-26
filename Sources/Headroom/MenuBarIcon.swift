import AppKit
import SwiftUI
import HeadroomCore

extension UsageLevel {
    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

enum MenuBarIcon {
    /// Two concentric rings: outer = current session, inner = weekly.
    static func image(session: Double?, weekly: Double?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            drawRing(center: center, radius: 7.4, lineWidth: 2.2, utilization: session)
            drawRing(center: center, radius: 3.6, lineWidth: 2.2, utilization: weekly)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawRing(center: NSPoint, radius: CGFloat, lineWidth: CGFloat, utilization: Double?) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        track.stroke()

        guard let utilization, utilization > 0 else { return }
        let fraction = min(utilization, 100) / 100
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                      endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        UsageLevel(utilization: utilization).nsColor.setStroke()
        arc.stroke()
    }
}

/// The combined icon: rings for whichever enabled store is closest to a limit.
struct CombinedMenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let shown = store.mostConstrained
        // Name the account only when there is more than one store it could be.
        MenuBarLabelContent(snapshot: shown?.snapshot, name: store.enabledStores.count > 1 ? shown?.label : nil,
                            alwaysShowName: false)
    }
}

/// One provider's own icon ("One icon per service"): rings for whichever of
/// its accounts (usually just one) is closest to a limit. Always named,
/// since the rings alone look the same for every provider.
struct GroupMenuBarLabel: View {
    let stores: [ProviderStore]

    var body: some View {
        let shown = stores.mostConstrained() ?? stores.first
        MenuBarLabelContent(snapshot: shown?.snapshot, name: shown?.label ?? "?", alwaysShowName: true)
    }
}

private struct MenuBarLabelContent: View {
    let snapshot: UsageSnapshot?
    let name: String?
    let alwaysShowName: Bool
    @AppStorage(SettingsKey.menuBarText) private var textMode = MenuBarTextMode.sessionUsed.rawValue

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image(session: snapshot?.session?.utilization, weekly: snapshot?.weekly?.utilization))
            if let text {
                Text(text).monospacedDigit()
            }
        }
    }

    private var text: String? {
        let percent = snapshot?.session.flatMap { percentText(for: $0) }
        switch (name, percent) {
        case let (name?, percent?): return "\(name) \(percent)"
        case let (name?, nil): return alwaysShowName ? name : nil
        case let (nil, percent): return percent
        }
    }

    private func percentText(for session: UsageWindow) -> String? {
        switch MenuBarTextMode(rawValue: textMode) ?? .none {
        case .none: return nil
        case .sessionUsed: return "\(UsageFormatting.percent(session.usedPercent))%"
        case .sessionRemaining: return "\(UsageFormatting.percent(session.remainingPercent))% left"
        }
    }
}
