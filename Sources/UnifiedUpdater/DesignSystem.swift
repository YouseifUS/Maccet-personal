import AppKit
import SwiftUI
import UpdaterCore

typealias ViewState<Value> = SwiftUI.State<Value>

// Semantic pairs follow the system appearance; stored identities remain unchanged.
enum Maccet {
    static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        func native(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? native(dark) : native(light) })
    }
    static let navy = color(0x032A43, 0x032A43)
    static let orange = color(0xFF6A00, 0xFF6A00)
    static let background = color(0xF5F4F0, 0x0C1620)
    static let surface = color(0xFFFFFF, 0x111F2B)
    static let secondarySurface = color(0xEEEFEA, 0x182A38)
    static let sidebar = color(0x032A43, 0x071B2A)
    static let sidebarSelection = color(0x193B52, 0x17364B)
    static let sidebarText = Color.white
    static let sidebarSecondary = color(0xA8B9C6, 0xA8B9C6)
    static let text = color(0x102B3D, 0xEEF4F7)
    static let secondary = color(0x576A78, 0xA7B8C5)
    static let tertiary = color(0x617481, 0x8FA5B5)
    static let border = color(0xDDE3E6, 0x2C4050)
    static let selection = color(0xE8EEF2, 0x193B52)
    static let accent = color(0xB54708, 0xFF9B57)
    static let softOrange = color(0xFFF1E6, 0x33261F)
    static var icon: NSImage {
        Bundle.module.url(forResource: "maccet-icon", withExtension: "png").flatMap(NSImage.init(contentsOf:)) ?? NSApplication.shared.applicationIconImage
    }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.2" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "3" }
}

enum StatusTone {
    case update, success, attention, failure, neutral, system
    var foreground: Color {
        switch self {
        case .update: return Maccet.color(0xB54708, 0xFFB27A)
        case .success: return Maccet.color(0x1E654A, 0x87D9B1)
        case .attention: return Maccet.color(0x82500A, 0xF5D084)
        case .failure: return Maccet.color(0xAA3038, 0xFFADB3)
        case .neutral: return Maccet.color(0x576A78, 0xB5C4CE)
        case .system: return Maccet.color(0x375A77, 0xB0CDE7)
        }
    }
    var background: Color {
        switch self {
        case .update: return Maccet.softOrange
        case .success: return Maccet.color(0xEAF5EE, 0x16362C)
        case .attention: return Maccet.color(0xFFF4D9, 0x392F1C)
        case .failure: return Maccet.color(0xFCEDEE, 0x3B222B)
        case .neutral: return Maccet.color(0xEEF1F3, 0x223340)
        case .system: return Maccet.color(0xEAF0F7, 0x1D3246)
        }
    }
    var symbol: String {
        switch self {
        case .update: return "arrow.up.circle"
        case .success: return "checkmark.circle"
        case .attention: return "exclamationmark.triangle"
        case .failure: return "exclamationmark.circle"
        case .neutral: return "minus.circle"
        case .system: return "lock.shield"
        }
    }
    static func forCheck(_ state: CheckState) -> Self {
        switch state {
        case .current: return .success
        case .updateAvailable: return .update
        case .failed: return .failure
        case .manual, .ambiguous: return .attention
        case .systemManaged: return .system
        default: return .neutral
        }
    }
    static func forTask(_ state: TaskState) -> Self {
        switch state {
        case .succeeded: return .success
        case .failed, .interrupted: return .failure
        case .needsAttention: return .attention
        case .installing, .verifying, .preflight: return .update
        default: return .neutral
        }
    }
}

struct StatusPill: View {
    let title: String
    var tone: StatusTone = .neutral
    var body: some View {
        Label(title, systemImage: tone.symbol)
            .font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(tone.foreground).padding(.horizontal, 8).padding(.vertical, 5)
            .background(tone.background, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .combine)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @ViewState private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14).frame(minHeight: 32)
            .foregroundStyle(enabled ? Maccet.navy : Maccet.secondary)
            .background(enabled ? (configuration.isPressed ? Maccet.color(0xE65F00, 0xE65F00) : hovering ? Maccet.color(0xF76300, 0xF76300) : Maccet.orange) : Maccet.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Maccet.accent : .clear, lineWidth: 2))
            .onHover { hovering = $0 }
    }
}

struct Surface<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Maccet.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(contrast == .increased ? Maccet.secondary : Maccet.border))
    }
}

struct BrandIcon: View {
    let size: CGFloat
    var body: some View { Image(nsImage: Maccet.icon).resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true) }
}
struct ApplicationIcon: View {
    let path: String
    var size: CGFloat = 36
    var body: some View { Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true) }
}
struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    var highlighted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.system(size: 12, weight: .medium)); Spacer(minLength: 4); Image(systemName: symbol).accessibilityHidden(true) }
                .foregroundStyle(highlighted ? Maccet.accent : Maccet.secondary)
            Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(highlighted ? Maccet.accent : Maccet.text)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Maccet.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background(highlighted ? Maccet.softOrange : Maccet.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Maccet.border))
    }
}
struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var action: String? = nil
    var perform: (() -> Void)? = nil
    var loading = false
    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 24)
            if loading { ProgressView().controlSize(.large).padding(8) }
            else { Image(systemName: symbol).font(.system(size: 42, weight: .light)).foregroundStyle(Maccet.secondary).accessibilityHidden(true) }
            Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Maccet.text)
            Text(message).font(.system(size: 13)).foregroundStyle(Maccet.secondary).multilineTextAlignment(.center).frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
            if let action, let perform { Button(action, action: perform).padding(.top, 4) }
            Spacer(minLength: 24)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct AttentionBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Some update sources need attention").fontWeight(.medium)
                Text("Available results are shown. Some apps could not be checked.").font(.system(size: 12))
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("View Sources") { model.screen = .sources }
            if model.setupNeedsAttention { Button(model.setupActionTitle, action: model.prepareSources).disabled(model.busy) }
        }.font(.system(size: 13)).foregroundStyle(StatusTone.attention.foreground).padding(16)
            .background(StatusTone.attention.background, in: RoundedRectangle(cornerRadius: 12))
    }
}

// Recognize only outcomes explicitly recorded by the existing update engine.
struct CleanupOutcome {
    let title: String
    let tone: StatusTone
    init?(message: String) {
        if message.hasPrefix("Removed this verified update's isolated downloads") { title = "Removed"; tone = .success }
        else if message.hasPrefix("Update verified; cleanup failed:") { title = "Cleanup needs attention"; tone = .attention }
        else if message.hasPrefix("Cleanup disabled; existing downloads were retained.") || message.hasPrefix("MacPorts artifacts and inactive versions were retained.") || message.hasPrefix("No cleanup performed. Failed-attempt artifacts retained at ") { title = "Retained"; tone = .neutral }
        else { return nil }
    }
}
