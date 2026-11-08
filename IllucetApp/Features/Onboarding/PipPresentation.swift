import SwiftUI
import UIKit

struct PipAnchorKey: PreferenceKey {
    static let defaultValue: [PipAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [PipAnchor: Anchor<CGRect>], nextValue: () -> [PipAnchor: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func pipAnchor(_ id: PipAnchor, active: Bool = true) -> some View {
        anchorPreference(key: PipAnchorKey.self, value: .bounds) { active ? [id: $0] : [:] }
    }
}

struct PipSprite: View {
    var expression = 0
    var talking = false
    var attention: PipGuideAttention = .forward
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15, paused: reduceMotion || scenePhase != .active)) { timeline in
            let tick = Int(timeline.date.timeIntervalSinceReferenceDate / 0.15)
            if expression == 0, attention == .up || attention == .down {
                Image(attention == .up ? "PipLookUp" : "PipLookDown")
                    .resizable().scaledToFit()
            } else {
                let pose = expression == 0 ? attention == .left ? 4 : attention == .right ? 5 : 0 : expression
                let frame = reduceMotion ? pose : talking && expression == 0 && ![4, 5].contains(pose) ? 2 + tick % 2 : pose == 0 && tick % 41 == 0 ? 1 : pose
                GeometryReader { proxy in
                    Image("PipAtlas")
                        .resizable()
                        .frame(width: proxy.size.width * 4, height: proxy.size.height * 3)
                        .offset(x: -CGFloat(frame % 4) * proxy.size.width, y: -CGFloat(frame / 4) * proxy.size.height)
                }
                .clipped()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct PipPresentation: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    @ObservedObject var pip: PipCoordinator
    var anchors: [PipAnchor: Anchor<CGRect>]

    var body: some View {
        // The observing view owns the GeometryReader's lifetime. Leaving an empty
        // reader in a cached preference overlay can intercept normal page touches.
        ZStack {
        if pip.isGuiding {
            GeometryReader { proxy in
                PipGuideSurface(pip: pip,
                    focus: (model.pipNavigationAnchor ?? pip.step?.anchor).flatMap { anchors[$0].map { proxy[$0] } },
                    size: proxy.size)
            }
        } else if pip.bubbleVisible {
            PipGuideSurface(pip: pip, focus: nil, size: .zero)
        }
        }
        .allowsHitTesting(pip.isGuiding || pip.bubbleVisible)
    }
}

private struct PipGuideSurface: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @EnvironmentObject private var model: IllucetAppModel
    @ObservedObject var pip: PipCoordinator
    var focus: CGRect?
    var size: CGSize
    @State private var dialogueHeight: CGFloat = 160
    private var maximumDialogueHeight: CGFloat {
        dynamicType.isAccessibilitySize ? min(380, size.height * 0.42) : 240
    }

    var body: some View {
        if let step = pip.step {
            guide(step)
                .opacity(pip.isLeaving ? 0 : 1)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
        } else if pip.bubbleVisible {
            VStack {
                HStack {
                    Spacer(minLength: 0)
                    companion
                        .frame(maxWidth: dynamicType.isAccessibilitySize ? .infinity : 310)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 56)
            .transition(.opacity)
        }
    }

    private func guide(_ step: PipGuideStep) -> some View {
        let placement = PipGuidePlacement(size: size, focus: focus,
            dialogueHeight: min(dialogueHeight, maximumDialogueHeight),
            mascotSize: dynamicType.isAccessibilitySize ? 70 : 96,
            preferredSide: step == .appearanceRow ? .below : step == .colors ? .above : nil)
        let attention = focus.map { PipGuideAttention(target: $0, mascot: placement.mascot) } ?? .forward
        return
        ZStack(alignment: .topTrailing) {
            spotlight
                .allowsHitTesting(false)
            Color.clear.contentShape(Rectangle())
                .onTapGesture { pip.advance() }
                .accessibilityHidden(true)
            VStack {
                HStack {
                    Text("PiP · \(step.rawValue + 1)/\(PipGuideStep.allCases.count)")
                        .font(.caption.weight(.medium))
                        .accessibilityIdentifier("pip.step")
                    Spacer()
                    Button("Skip guide") { pip.leaveGuide(skipped: true) }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("pip.skip")
                }
                .foregroundStyle(.white)
                .padding(16)
                Spacer()
            }
            guideDialogue
                .frame(width: placement.dialogue.width, height: placement.dialogue.height)
                .position(x: placement.dialogue.midX, y: placement.dialogue.midY)
            Button { pip.poke() } label: {
                PipSprite(expression: pip.expression,
                    talking: pip.navigationCue == nil && !pip.finishedTyping && !pip.interrupted,
                    attention: attention)
                    .frame(width: placement.mascot.width, height: placement.mascot.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("PiP")
            .accessibilityValue(pip.expression == 0 ? attention.accessibilityValue : "")
            .accessibilityIdentifier("pip.mascot")
            .position(x: placement.mascot.midX, y: placement.mascot.midY)
        }
    }

    private var spotlight: some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            if let focus, focus.width > 0, focus.height > 0 {
                path.addRoundedRect(in: focus.insetBy(dx: -5, dy: -5), cornerSize: .init(width: 16, height: 16))
            }
        }
        .fill(.black.opacity(0.57), style: FillStyle(eoFill: true))
        .overlay {
            if let focus {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.85), lineWidth: 2)
                    .frame(width: focus.width + 10, height: focus.height + 10)
                    .position(x: focus.midX, y: focus.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private var guideDialogue: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("PiP").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                if let cue = pip.navigationCue {
                    Text(cue).font(.body.weight(.medium))
                        .accessibilityIdentifier("pip.route")
                } else {
                // Invisible complete text reserves space, preventing typewriter layout jumps.
                brandedText(pip.text).hidden().overlay(alignment: .topLeading) {
                    brandedText(pip.displayedText)
                }
                .font(.body)
                .accessibilityLabel(pip.text)
                .accessibilityIdentifier("pip.dialogue")
                if pip.step == .notifications {
                    Button("Enable notifications") { model.requestNotifications() }
                        .buttonStyle(.bordered)
                        .disabled(model.isRequestingNotificationAuthorization)
                        .accessibilityIdentifier("pip.notifications")
                }
                Text(pip.step == .finish ? "Tap to finish guide" : pip.finishedTyping ? "Tap to continue" : "Tap to finish · Tap again to continue")
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dialogueHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: 500)
            .frame(height: min(dialogueHeight, maximumDialogueHeight), alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .contentShape(RoundedRectangle(cornerRadius: 22))
            .onTapGesture { pip.advance() }
            .accessibilityAction(named: "Continue") { pip.advance() }
            .accessibilityElement(children: .contain)
            if UIAccessibility.isVoiceOverRunning {
                Button("Continue") { pip.advance() }
                    .accessibilityIdentifier("pip.next")
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: 500)
    }

    private var companion: some View {
        HStack(alignment: .top, spacing: 8) {
            PipSprite(expression: pip.expression, talking: !pip.finishedTyping)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text("PiP").font(.caption.weight(.bold))
                brandedText(pip.displayedText).font(.subheadline).accessibilityLabel(pip.text)
                if pip.showsDownloadSettingsButton {
                    Button("Show settings") { pip.showDownloadScreenSettings() }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("pip.downloadSettings")
                }
                if pip.showsNotificationSettingsButton {
                    Button("Show settings") { pip.showNotificationSettings() }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("pip.notificationSettings")
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture { pip.dismissBubble() }
        .accessibilityAction(named: "Dismiss PiP") { pip.dismissBubble() }
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pip.companion")
    }
}

enum PipGuideAttention: String {
    case forward, up, down, left, right

    var accessibilityValue: String {
        switch self {
        case .forward: "Facing you"
        case .up: "Looking up"
        case .down: "Looking down"
        case .left: "Pointing left"
        case .right: "Pointing right"
        }
    }

    init(target: CGRect, mascot: CGRect) {
        // Aim at the nearest point of the actual highlighted control, rather
        // than choosing a horizontal gesture from its screen-half alone.
        let dx = min(max(mascot.midX, target.minX), target.maxX) - mascot.midX
        let dy = min(max(mascot.midY, target.minY), target.maxY) - mascot.midY
        if abs(dy) > abs(dx) { self = dy < 0 ? .up : .down }
        else if dx != 0 { self = dx < 0 ? .left : .right }
        else { self = .forward }
    }
}

struct PipGuidePlacement {
    enum Side: CaseIterable { case right, left, below, above }
    let dialogue: CGRect
    let mascot: CGRect

    init(size: CGSize, focus: CGRect?, dialogueHeight: CGFloat, mascotSize: CGFloat, preferredSide: Side? = nil) {
        let width = min(500, max(0, size.width - 36))
        let height = min(dialogueHeight, max(0, size.height - 100))
        let top = focus.map { $0.midY > size.height * 0.5 } ?? false
        let dialogueFrame = CGRect(x: (size.width - width) / 2, y: top ? 64 : size.height - height - 24,
                          width: width, height: height)
        dialogue = dialogueFrame
        let bounds = CGRect(x: 12, y: 64, width: max(0, size.width - 24), height: max(0, size.height - 80))
        let target = focus ?? CGRect(x: dialogueFrame.minX + 12, y: dialogueFrame.minY - mascotSize - 10, width: 0, height: 0)
        let orderedSides = preferredSide.map { preferred in [preferred] + Side.allCases.filter { $0 != preferred } } ?? Side.allCases
        let candidates = [mascotSize, min(mascotSize, 80), min(mascotSize, 64)].flatMap { length in
            orderedSides.map { side in
                switch side {
                case .right: CGRect(x: target.maxX + 8, y: target.midY - length / 2, width: length, height: length)
                case .left: CGRect(x: target.minX - length - 8, y: target.midY - length / 2, width: length, height: length)
                case .below: CGRect(x: min(max(target.minX, bounds.minX), bounds.maxX - length), y: target.maxY + 8, width: length, height: length)
                case .above: CGRect(x: min(max(target.minX, bounds.minX), bounds.maxX - length), y: target.minY - length - 8, width: length, height: length)
                }
            }
        }
        mascot = candidates.first { bounds.contains($0) && !$0.intersects(dialogueFrame) && (focus == nil || !$0.intersects(target)) }
            ?? CGRect(x: bounds.minX, y: min(max(top ? dialogueFrame.maxY + 8 : dialogueFrame.minY - mascotSize - 8, bounds.minY), bounds.maxY - mascotSize), width: mascotSize, height: mascotSize)
    }
}
