import SwiftUI

struct PipSettingsView: View {
    @EnvironmentObject private var model: IllucetAppModel
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    PipSettingsPortrait(isVisible: model.selectedTab == .settings
                        && model.settingsNavigationPath.last == .pip && model.pipGuideStep == nil)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PiP").font(.system(.title2, design: .rounded, weight: .semibold))
                        Text("Tiny paws. Occasional guidance.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                PipEnabledToggle()
                Picker("Activity", selection: Binding(
                    get: { model.settings.pipPreferences.frequency },
                    set: { model.settings.pipPreferences.frequency = $0 }
                )) {
                    ForEach(PipFrequency.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!model.settings.pipPreferences.enabled)
                .accessibilityIdentifier("pip.frequency")
                .pipAnchor(.settings)
            } footer: {
                Text("Occasional tips keeps interruptions rare. Tips & download updates also reacts when downloads start, finish or need attention.")
            }
            Section {
                Button("Replay guide", systemImage: "play.circle") {
                    model.replaysPipGuide = true
                }
                .disabled(model.isAnalyzing || model.presentsOnboarding)
                .accessibilityIdentifier("pip.replay")
            }
        }
        .settingsFormBackground()
        .navigationTitle("PiP")
        .navigationBarBackButtonHidden(model.pipGuideStep != nil)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PipSettingsPortrait: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @State private var scratching = false
    @State private var reaction: Int?
    @State private var nextReaction = 0
    @State private var motionStartedAt = Date.now

    let isVisible: Bool

    private let reactions = [(6, "Happy"), (11, "Shy"), (8, "Waving"), (9, "Side-eye")]
    private var canAnimate: Bool { isVisible && phase == .active && !reduceMotion }

    var body: some View {
        Button {
            scratching = false
            motionStartedAt = .now
            reaction = nextReaction
            nextReaction = (nextReaction + 1) % reactions.count
        } label: {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !canAnimate)) { context in
                let motion = motion(at: context.date)
                ZStack {
                    if scratching {
                        Image("PipEarScratch").resizable().scaledToFit().scaleEffect(1.1)
                            .transition(.opacity)
                    } else {
                        PipSprite(expression: reaction.map { reactions[$0].0 } ?? 0)
                            .id(reaction)
                            .transition(.opacity)
                    }
                }
                .animation(canAnimate ? .easeInOut(duration: 0.14) : nil, value: reaction)
                .animation(canAnimate ? .easeInOut(duration: 0.14) : nil, value: scratching)
                .scaleEffect(x: motion.scaleX, y: motion.scaleY, anchor: .bottom)
                .rotationEffect(.degrees(motion.rotation), anchor: .bottom)
                .offset(x: motion.x, y: motion.y)
            }
            .frame(width: 78, height: 78)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("PiP")
        .accessibilityValue(reaction.map { reactions[$0].1 } ?? (scratching ? "Scratching ear" : "Relaxed"))
        .accessibilityHint("Tap for a reaction")
        .accessibilityIdentifier("pip.settingsPortrait")
        .task(id: canAnimate) {
            guard canAnimate else { scratching = false; reaction = nil; return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(12))
                    guard reaction == nil else { continue }
                    motionStartedAt = .now
                    scratching = true
                    try await Task.sleep(for: .milliseconds(780))
                    scratching = false
                } catch { return }
            }
        }
        .task(id: reaction) {
            guard reaction != nil else { return }
            do { try await Task.sleep(for: .milliseconds(1_500)) } catch { return }
            reaction = nil
        }
        .onDisappear { scratching = false; reaction = nil }
    }

    private struct Motion {
        var x = 0.0
        var y = 0.0
        var rotation = 0.0
        var scaleX = 1.0
        var scaleY = 1.0
    }

    private func motion(at date: Date) -> Motion {
        guard canAnimate else { return Motion() }
        // Time-based motion avoids per-frame state updates. Each gesture eases
        // back to neutral, even when another tap interrupts it.
        let elapsed = max(0, date.timeIntervalSince(motionStartedAt))
        let breath = sin(date.timeIntervalSinceReferenceDate * 2.1) * 0.008
        var result = Motion(scaleX: 1 - breath / 2, scaleY: 1 + breath)
        if scratching {
            result.rotation = sin(elapsed * 32) * 2.5
            result.y = -abs(sin(elapsed * 16))
        } else if let reaction {
            let progress = min(elapsed / 1.35, 1)
            let envelope = pow(sin(.pi * progress), 2)
            switch reaction {
            case 0: // A little crouch, two happy hops, then a soft landing.
                result.y = -9 * envelope * (0.65 + 0.35 * cos(4 * .pi * progress))
                let stretch = sin(4 * .pi * progress) * envelope * 0.07
                result.scaleX -= stretch
                result.scaleY += stretch
            case 1: // Pull in, tilt bashfully and peek back up.
                result.x = -3 * envelope
                result.rotation = -8 * envelope
                result.scaleX -= 0.04 * envelope
                result.scaleY -= 0.03 * envelope
            case 2: // Rock through the greeting rather than holding a still pose.
                result.rotation = sin(6 * .pi * progress) * envelope * 7
                result.y = -2 * envelope
            default: // Lean over for a curious look, then settle back.
                result.x = -5 * envelope
                result.rotation = -5 * envelope
                result.y = -envelope
            }
        }
        return result
    }
}

struct PipEnabledToggle: View {
    @EnvironmentObject private var model: IllucetAppModel
    @State private var showsAppeal = false
    var body: some View {
        Toggle("Show PiP", isOn: Binding(
            get: { model.settings.pipPreferences.enabled },
            set: { enabled in
                if !enabled && !(model.firstRunState.pip?.disableConfirmed ?? false) {
                    showsAppeal = true
                } else { model.settings.pipPreferences.enabled = enabled }
            }
        ))
        .accessibilityIdentifier("pip.enabled")
        .sheet(isPresented: $showsAppeal) {
            VStack(spacing: 18) {
                PipSprite(expression: 7).frame(width: 130, height: 130)
                Text("One last puppy-eyed look?").font(.headline)
                Text("I could stay very quiet…").foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button("Keep PiP") { showsAppeal = false }
                    Button("Turn Off") {
                        var local = model.firstRunState.pip ?? .init()
                        local.disableConfirmed = true
                        model.firstRunState.pip = local
                        model.settings.pipPreferences.enabled = false
                        model.settingsChanged()
                        showsAppeal = false
                    }
                    .accessibilityIdentifier("pip.turnOff")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(24)
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
        }
    }
}
