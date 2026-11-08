import SwiftUI
import UIKit

enum IllucetTheme {
    static let accent = adaptive(light: 0x006D66, dark: 0x77DED0)
    static let violet = adaptive(light: 0x6550A6, dark: 0xC4B4FF)
    static let success = adaptive(light: 0x287241, dark: 0x86D79D)
    static let warning = adaptive(light: 0x95600B, dark: 0xF2C477)
    static let danger = adaptive(light: 0xBD3447, dark: 0xFF99A3)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x1B2527)
    static let raisedCard = adaptive(light: 0xF0F5F3, dark: 0x273537)
    static let border = Color(uiColor: .separator).opacity(0.38)
    static let input = adaptive(light: 0xF0F5F3, dark: 0x111C1E)
    static let actionFill = Color(red: 0.0, green: 0.37, blue: 0.34)
    static let contentWidth: CGFloat = 820

    static let background = LinearGradient(
        colors: [
            adaptive(light: 0xF0F5F2, dark: 0x142123),
            adaptive(light: 0xF7F8F5, dark: 0x101719),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

struct IllucetBackground: View {
    @Environment(\.illucetPalette) private var theme
    var body: some View {
        theme.background
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
struct IllucetCardModifier: ViewModifier {
    @Environment(\.illucetPalette) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(theme.card)
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: 24,
                            style: .continuous
                        )
                        .stroke(
                            contrast == .increased
                                ? Color.primary.opacity(0.55)
                                : IllucetTheme.border,
                            lineWidth: 1
                        )
                    }
            )
    }
}

extension View {
    func illucetCard(padding: CGFloat = 16) -> some View {
        modifier(IllucetCardModifier(padding: padding))
    }

    func illucetContentWidth() -> some View {
        frame(maxWidth: IllucetTheme.contentWidth)
            .frame(maxWidth: .infinity)
    }
}

struct IllucetSectionHeader: View {
    @Environment(\.illucetPalette) private var theme
    let title: String
    var subtitle: String?
    var systemImage: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.foregroundAccent)
                    .frame(width: 34, height: 34)
                    .background(theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                brandedText(title)
                    .font(.headline)
                if let subtitle {
                    brandedText(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

struct IllucetPill: View {
    @Environment(\.illucetPalette) private var theme
    let text: String
    var color: Color? = nil
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color ?? theme.foregroundAccent)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background((color ?? theme.accent).opacity(0.13), in: Capsule())
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.illucetPalette) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(theme.actionText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                theme.actionFill,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.outline, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
    }
}

struct EmptyStateView: View {
    @Environment(\.illucetPalette) private var theme
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?
    var accessibilityPrefix = "empty"

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(theme.foregroundAccent)
                .frame(width: 88, height: 88)
                .background(theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 28))
                .accessibilityHidden(true)
            brandedText(title)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 330)
            if let actionTitle, let action {
                VStack(spacing: 10) {
                    Button(actionTitle, action: action)
                        .buttonStyle(PrimaryActionButtonStyle())
                        .accessibilityIdentifier(
                            "\(accessibilityPrefix).primary"
                        )
                    if let secondaryActionTitle,
                       let secondaryAction {
                        Button(
                            secondaryActionTitle,
                            action: secondaryAction
                        )
                        .font(.subheadline.weight(.semibold))
                        .controlSize(.large)
                        .accessibilityIdentifier(
                            "\(accessibilityPrefix).secondary"
                        )
                    }
                }
                .frame(maxWidth: 300)
                .padding(.top, 6)
            }
        }
        .padding(28)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension DownloadJobState {
    func tint(accent: Color) -> Color {
        switch self {
        case .completed: IllucetTheme.success
        case .failed, .cancelled: IllucetTheme.danger
        case .needsAttention: IllucetTheme.warning
        case .running: accent
        case .paused, .waitingForNetwork, .waitingForWiFi,
             .waitingForCellularApproval, .waitingForRetry,
             .waitingForPower:
            IllucetTheme.warning
        case .queued: .secondary
        }
    }

    var label: String {
        switch self {
        case .waitingForNetwork: "Waiting for Network"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .waitingForCellularApproval: "Cellular Approval"
        case .waitingForRetry: "Retry Scheduled"
        case .waitingForPower: "Waiting for power"
        case .needsAttention: "Needs attention"
        default: rawValue.capitalized
        }
    }
}

extension TimeInterval {
    var conciseDuration: String {
        guard isFinite, self >= 0 else { return "—" }
        let total = Int(self.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3_600)h \((total % 3_600) / 60)m"
    }
}

struct IllucetPalette: Equatable {
    var selected: AppAccentColor?
    var oled = false
    var dark = false
    private var custom: AppAccentColor? { selected.flatMap { $0.isValid ? $0 : nil } }
    var accent: Color {
        guard let custom else { return IllucetTheme.accent }
        return Color(.sRGB, red: custom.red, green: custom.green, blue: custom.blue, opacity: 1)
    }
    var foregroundAccent: Color {
        guard let custom else { return IllucetTheme.accent }
        if dark && custom.luminance < 0.08 { return Color(white: 0.8) }
        if !dark && custom.luminance > 0.6 { return Color(white: 0.25) }
        return accent
    }
    var actionFill: Color { custom == nil ? IllucetTheme.actionFill : accent }
    var actionText: Color { (custom?.luminance ?? 0) > 0.179 ? .black : .white }
    var badgeUsesDarkText: Bool {
        guard let custom else { return dark }
        if dark && custom.luminance < 0.08 { return true }
        if !dark && custom.luminance > 0.6 { return false }
        return custom.luminance > 0.179
    }
    var badgeText: Color { badgeUsesDarkText ? .black : .white }
    var outline: Color { dark ? .white.opacity(0.35) : .black.opacity(0.25) }
    var card: Color { oled && dark ? Color(white: 0.075) : IllucetTheme.card }
    var raisedCard: Color { oled && dark ? Color(white: 0.12) : IllucetTheme.raisedCard }
    var input: Color { oled && dark ? Color(white: 0.045) : IllucetTheme.input }
    var background: LinearGradient { oled && dark
        ? LinearGradient(colors: [.black, .black], startPoint: .top, endPoint: .bottom)
        : IllucetTheme.background }
}
private struct IllucetPaletteKey: EnvironmentKey {
    static let defaultValue = IllucetPalette()
}
extension EnvironmentValues {
    var illucetPalette: IllucetPalette {
        get { self[IllucetPaletteKey.self] }
        set { self[IllucetPaletteKey.self] = newValue }
    }
}
struct IllucetAppearanceModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let settings: AppSettings
    func body(content: Content) -> some View {
        let palette = IllucetPalette(selected: settings.accentColor,
            oled: settings.oledDarkBackground ?? false, dark: scheme == .dark)
        content.environment(\.illucetPalette, palette).tint(palette.foregroundAccent)
    }
}
