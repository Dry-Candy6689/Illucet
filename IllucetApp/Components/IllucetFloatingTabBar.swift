import SwiftUI
import UIKit

struct IllucetFloatingTabBar: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var contentSize: CGSize = .zero
    @State private var isPressing = false
    @State private var previewX: CGFloat?
    @State private var pressOrigin = CGPoint.zero
    @State private var acquisitionStartedAt: TimeInterval = 0
    @State private var maximumTravel: CGFloat = 0
    private let itemSpacing: CGFloat = 3
    private let acquisitionDuration: TimeInterval = 0.18
    private var reducesMotion: Bool { systemReduceMotion }
    private var previewTab: AppTab { previewX.flatMap { tab(at: CGPoint(x: $0, y: 0)) } ?? model.selectedTab }
    private var selectionAnimation: Animation? {
        systemReduceMotion
            ? nil : .spring(duration: 0.10, bounce: 0.15)
    }

    private var highlightAnimation: Animation? {
        systemReduceMotion
            ? nil : .timingCurve(0.1, 1.35, 0.2, 1, duration: 0.15)
    }

    var body: some View {
        HStack(spacing: itemSpacing) {
            ForEach(AppTab.allCases) { tab in
                VStack(spacing: 5) {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .scaleEffect(previewTab == tab ? (isPressing && !reducesMotion ? 1.16 : 1.05) : 1)
                        .animation(selectionAnimation, value: previewTab)
                        .overlay(alignment: .topTrailing) {
                            if tab == .queue, let badge = model.queueTabBadge {
                                queueBadge(badge)
                                    .offset(x: 12, y: -8).accessibilityHidden(true)
                            }
                        }
                    brandedText(tab.rawValue).font(.caption2.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .padding(.vertical, 5)
                .foregroundStyle(previewTab == tab ? theme.foregroundAccent : .secondary)
                .contentShape(Rectangle())
                .pipAnchor(.settingsTab, active: tab == .settings)
                .onTapGesture { model.selectTab(tab) }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.selectTab(tab) }
                .accessibilityLabel(tab.rawValue)
                .accessibilityValue(tab == .queue ? model.queueTabBadge?.accessibilityLabel ?? "" : "")
                .accessibilityAddTraits(model.selectedTab == tab ? .isSelected : [])
                .accessibilityIdentifier("navigation.\(String(describing: tab).lowercased())")
            }
        }
        .background(alignment: .leading) {
            GeometryReader { geometry in
                let count = CGFloat(AppTab.allCases.count)
                let width = max(0, (geometry.size.width - itemSpacing * (count - 1)) / count)
                let selectedIndex = AppTab.allCases.firstIndex(of: model.selectedTab) ?? 0
                let index = CGFloat(layoutDirection == .rightToLeft
                    ? AppTab.allCases.count - 1 - selectedIndex : selectedIndex)
                let restingX = width / 2 + index * (width + itemSpacing)
                let fingerX = previewX
                // One persistent highlight moves independently of the page and
                // buttons, avoiding insertion/removal crossfades during switching.
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(theme.accent.opacity(0.13))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.outline.opacity(0.4)))
                    .frame(width: width, height: geometry.size.height)
                    .position(x: fingerX.map { min(max($0, width / 2), geometry.size.width - width / 2) }
                        ?? restingX, y: geometry.size.height / 2)
                    // Fixed total duration includes overshoot and rebound; no spring tail.
                    .animation(isPressing ? nil : highlightAnimation, value: model.selectedTab)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
        .contentShape(Rectangle())
        .gesture(TabBarPressGesture { state, location in
            switch state {
            case .began:
                isPressing = true
                pressOrigin = location
                maximumTravel = 0
                acquisitionStartedAt = ProcessInfo.processInfo.systemUptime
                withAnimation(reducesMotion ? nil : .easeOut(duration: acquisitionDuration)) {
                    previewX = tabCenter(near: location.x)
                }
            case .changed:
                maximumTravel = max(maximumTravel, hypot(location.x - pressOrigin.x, location.y - pressOrigin.y))
                guard maximumTravel >= 3, tab(at: location) != nil else { return }
                let remaining = acquisitionDuration - (ProcessInfo.processInfo.systemUptime - acquisitionStartedAt)
                if !reducesMotion, remaining > 0 {
                    // Retarget the current glide instead of snapping if the finger
                    // moves before acquisition finishes. Its deadline stays fixed.
                    withAnimation(.easeOut(duration: remaining)) { previewX = location.x }
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { previewX = location.x }
                }
            case .ended:
                maximumTravel = max(maximumTravel, hypot(location.x - pressOrigin.x, location.y - pressOrigin.y))
                if let target = tab(at: location), maximumTravel < 8 || target != model.selectedTab {
                    model.selectTab(target)
                }
                finishPreview()
            case .cancelled, .failed:
                finishPreview()
            default:
                break
            }
        })
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 27).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        .padding(.horizontal, 18).padding(.bottom, 5)
        .environment(\.symbolVariants, .none)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("navigation.floatingBar")
    }

    @ViewBuilder
    private func queueBadge(_ badge: QueueTabBadge) -> some View {
        if badge == .completed {
            Circle().fill(theme.foregroundAccent)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(theme.raisedCard, lineWidth: 2))
        } else {
            Image(systemName: badge.systemImage)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(theme.badgeText)
                .frame(width: 18, height: 18)
                .background(theme.foregroundAccent, in: Circle())
                .overlay(Circle().stroke(theme.raisedCard, lineWidth: 1.5))
        }
    }

    private func finishPreview() {
        isPressing = false
        withAnimation(reducesMotion ? nil : .easeOut(duration: 0.11)) { previewX = nil }
    }

    private func tabCenter(near x: CGFloat) -> CGFloat {
        let count = CGFloat(AppTab.allCases.count)
        let width = max(0, (contentSize.width - itemSpacing * (count - 1)) / count)
        let stride = width + itemSpacing
        let index = min(max(floor((x + itemSpacing / 2) / stride), 0), count - 1)
        return width / 2 + index * stride
    }

    private func tab(at location: CGPoint) -> AppTab? {
        // A touch that began on the bar stays attached below it, including
        // the home-indicator inset. Gestures beginning down there remain iOS-owned.
        guard contentSize.width > 0, location.y >= -24,
              location.x >= -24, location.x <= contentSize.width + 24
        else { return nil }
        let count = AppTab.allCases.count
        let width = (contentSize.width - itemSpacing * CGFloat(count - 1)) / CGFloat(count)
        let physicalIndex = min(max(Int((location.x + itemSpacing / 2) / (width + itemSpacing)), 0), count - 1)
        let index = layoutDirection == .rightToLeft ? count - 1 - physicalIndex : physicalIndex
        return AppTab.allCases[index]
    }
}

/// An explicit short press avoids waiting for SwiftUI drag recognition at rest.
/// SwiftUI still owns the tab labels, accessibility actions and highlight rendering.
private struct TabBarPressGesture: UIGestureRecognizerRepresentable {
    var action: (UIGestureRecognizer.State, CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.035
        recognizer.allowableMovement = .greatestFiniteMagnitude
        recognizer.cancelsTouchesInView = true
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        action(recognizer.state, context.converter.localLocation)
    }
}
