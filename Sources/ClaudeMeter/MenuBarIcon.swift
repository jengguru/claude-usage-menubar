import AppKit
import SwiftUI
import ClaudeMeterCore

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

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore
    @AppStorage(SettingsKey.menuBarText) private var textMode = MenuBarTextMode.sessionUsed.rawValue

    var body: some View {
        let session = store.snapshot?.session
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image(session: session?.utilization, weekly: store.snapshot?.weekly?.utilization))
            if let session, let text = text(for: session) {
                Text(text).monospacedDigit()
            }
        }
    }

    private func text(for session: UsageWindow) -> String? {
        switch MenuBarTextMode(rawValue: textMode) ?? .none {
        case .none: return nil
        case .sessionUsed: return "\(UsageFormatting.percent(session.usedPercent))%"
        case .sessionRemaining: return "\(UsageFormatting.percent(session.remainingPercent))% left"
        }
    }
}
