import SwiftUI
import UIKit
import UserNotifications

final class IllucetApplicationDelegate:
    NSObject,
    UIApplicationDelegate, UNUserNotificationCenterDelegate
{
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await IllucetApplicationServices.model.openDownloadNotification(
            jobID: (info["job_id"] as? String).flatMap(UUID.init(uuidString:)),
            requestID: (info["request_id"] as? String).flatMap(UUID.init(uuidString:)))
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == AppIdentity.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundSessionEventBroker.shared.register(
            sessionIdentifier: identifier,
            completion: completionHandler
        )
    }
}

@main
struct IllucetApp: App {
    @UIApplicationDelegateAdaptor(IllucetApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var model = IllucetApplicationServices.model

    var body: some Scene {
        WindowGroup {
            launchContent
                .preferredColorScheme(model.preferredColorScheme)
                .modifier(IllucetAppearanceModifier(settings: model.settings))
                .onAppear {
                    UIDevice.current.isBatteryMonitoringEnabled = true
                    updatePowerState()
                }
                .onChange(of: model.startupState) { _, state in
                    if state == .ready { model.checkForUpdatesIfDue() }
                }
                .onChange(of: model.settings.automaticUpdateChecks) { _, _ in model.automaticUpdatePreferenceChanged() }
                .onReceive(NotificationCenter.default.publisher(for: .illucetSharedLinkReceived)) { _ in model.refreshSharedLinks() }
                .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in updatePowerState() }
                .modifier(IllucetSceneLifecycle(model: model))
        }
    }

    private func updatePowerState() {
        let state = UIDevice.current.batteryState
        Task { await model.coordinator.updatePowerState(connected: state == .charging || state == .full) }
    }

    @ViewBuilder
    private var launchContent: some View {
        #if DEBUG
        if model.fixtureMode && ProcessInfo.processInfo.arguments.contains("--ui-screen=runtime-proof-inspection") {
            NavigationStack { DiagnosticsView().environmentObject(model) }
        } else if ProcessInfo.processInfo.arguments.contains("--shared-link-proof") {
            SharedLinkProofView()
        } else if ProcessInfo.processInfo.arguments.contains("--live-activity-proof") || ProcessInfo.processInfo.environment["ILLUCET_LIVE_ACTIVITY_PROOF"] == "1" {
            LiveActivityProofView()
        } else if ProcessInfo.processInfo.arguments.contains("--youtube-signin-probe") {
            YouTubeSignInProbeView(runtime: model.runtime)
        } else if IllucetLaunchRouting.usesStage0Harness(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            Stage0HarnessView()
        } else {
            normalLaunchContent
        }
        #else
        normalLaunchContent
        #endif
    }

    private var normalLaunchContent: some View {
        IllucetRootView()
            .environmentObject(model)
    }
}


/// Each window reports its own scene; one inactive window cannot revoke another.
private struct IllucetSceneLifecycle: ViewModifier {
    @ObservedObject var model: IllucetAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneID = UUID()
    @State private var needsClipboardCheck = true

    func body(content: Content) -> some View {
        content
            .onAppear { report(scenePhase) }
            .onChange(of: scenePhase) { _, phase in report(phase) }
            .onDisappear { model.sceneActivityChanged(id: sceneID, active: false) }
    }

    private func report(_ phase: ScenePhase) {
        model.sceneActivityChanged(id: sceneID, active: phase.permitsDownloadExecution)
        if phase == .background { needsClipboardCheck = true }
        if phase == .active {
            Task { await model.refreshNotificationAuthorization() }
            let state = UIDevice.current.batteryState
            Task { await model.coordinator.updatePowerState(connected: state == .charging || state == .full) }
            model.refreshSharedLinks()
            if needsClipboardCheck {
                needsClipboardCheck = false
                Task { await model.checkClipboardOnActivation() }
            }
            model.checkForUpdatesIfDue()
        }
    }
}

extension ScenePhase {
    // Control Center, notification panels and system prompts leave the scene
    // foreground-inactive. Only a real background transition revokes execution.
    var permitsDownloadExecution: Bool { self != .background }
}

enum IllucetLaunchRouting {
    static func usesStage0Harness(arguments: [String]) -> Bool {
        #if DEBUG
        arguments.contains("--stage0-autorun")
        #else
        false
        #endif
    }

    static func usesUITestFixtures(arguments: [String], override: Bool? = nil) -> Bool {
        #if DEBUG
        override ?? arguments.contains("--ui-testing")
        #else
        false
        #endif
    }
}
