import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct IllucetRootView: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    @StateObject private var pip = PipCoordinator()
    @Environment(\.scenePhase) private var pipScenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var keyboardVisible = false
    @State private var floatingBarHeight: CGFloat = 83
    private var usesFloatingBar: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        Group {
            if model.startupState.blocksInteraction {
                startupView
            } else {
                mainContent
            }
        }
        .onOpenURL { model.receiveDeepLink($0) }
        .onChange(of: model.canPresentShortcutOptions) { _, available in
            if available { model.presentDeferredShortcutHandoff() }
        }
    }

    private var mainContent: some View {
        workspace
        .allowsHitTesting(!pip.isLeaving)
        .overlay {
            theme.background
                .opacity(pip.exitCoverOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlayPreferenceValue(PipAnchorKey.self) { anchors in
            PipPresentation(pip: pip, anchors: anchors)
        }
        .task {
            pip.attach(model, active: pipScenePhase == .active,
                fastText: ProcessInfo.processInfo.arguments.contains("--pip-fast-text") && _isDebugAssertConfiguration(),
                reduceMotion: reduceMotion)
        }
        .onChange(of: pipScenePhase) { _, phase in pip.setActive(phase == .active) }
        .onChange(of: reduceMotion) { _, value in pip.reduceMotion = value }
        .onDisappear { if !pip.isLeaving { pip.detach() } }
        .onChange(of: model.presentsOnboarding) { _, shown in if shown { pip.startGuide() } }
        .onChange(of: model.replaysPipGuide) { _, shown in if shown { pip.startGuide() } }
        .onChange(of: model.jobs) { _, _ in pip.observeJobs() }
        .onChange(of: model.foregroundDownloadCompletions) { _, _ in pip.receiveDownloadCompletions() }
        .onChange(of: model.selectedTab) { _, _ in pip.pageChanged() }
        .onChange(of: model.settings.pipPreferences) { _, _ in pip.preferencesChanged() }
        .onChange(of: model.settings.experience) { _, _ in pip.preferencesChanged() }
        .onChange(of: model.settings.hasNotificationEventsEnabled) { _, _ in pip.preferencesChanged() }
        .onChange(of: model.notificationsAuthorized) { _, _ in pip.preferencesChanged() }
        .onChange(of: model.presentsPastePermissionTip) { _, shown in
            if shown {
                pip.dismissBubble()
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .onChange(of: model.URLText) { _, _ in pip.activityChanged(); pip.dismissBubble() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            pip.keyboardChanged(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            pip.keyboardChanged(false)
        }
        .sheet(isPresented: $model.presentsMetadata) {
            if let metadata = model.analyzedMetadata {
                MetadataSheet(metadata: metadata)
                    .environmentObject(model)
            }
        }
        .sheet(item: $model.shortcutHandoff, onDismiss: model.shortcutHandoffDidDismiss) { handoff in
            ShortcutHandoffView(handoff: handoff).environmentObject(model)
        }
        .sheet(isPresented: $model.presentsConfiguration) {
            if let metadata = model.analyzedMetadata {
                DownloadConfigurationView(metadata: metadata)
                    .environmentObject(model)
            }
        }
        .sheet(isPresented: $model.presentsConfirmation) {
            if let metadata = model.analyzedMetadata {
                DownloadConfirmationView(metadata: metadata)
                    .environmentObject(model)
            }
        }
        .sheet(isPresented: $model.presentsQuickStartConfirmation) {
            if let metadata = model.analyzedMetadata {
                QuickStartConfirmationView(metadata: metadata)
                    .environmentObject(model)
            }
        }
        .sheet(isPresented: $model.presentsPlaylistBatch) {
            if model.playlistDraft != nil {
                PlaylistBatchFlowView()
                    .environmentObject(model)
            }
        }
        .sheet(isPresented: $model.presentsDownloadArchive) {
            DownloadArchiveView()
                .environmentObject(model)
        }
        .sheet(item: $model.selectedJob) { job in
            JobDetailView(job: job)
                .environmentObject(model)
        }
        .sheet(item: $model.selectedHistoryRecord) { record in
            OutputDetailView(record: record, context: .history)
                .environmentObject(model)
        }
        .sheet(
            item: pendingShareRequest,
            onDismiss: model.shareSheetDidDismiss
        ) { request in
            SystemShareSheet(request: request) { state, error in
                model.finishShare(
                    request,
                    state: state,
                    errorDescription: error
                )
            }
            .accessibilityIdentifier(
                "share.sheet.\(request.jobID.uuidString)"
            )
            .interactiveDismissDisabled()
        }
        .confirmationDialog(
            "A file with this name already exists",
            isPresented: duplicateDialogPresented,
            titleVisibility: .visible,
            presenting: model.pendingDuplicateConflict
        ) { conflict in
            Button("Replace Existing File", role: .destructive) {
                model.resolveDuplicate(
                    conflict,
                    handling: .overwrite
                )
            }
            Button("Keep Both — Add Number") {
                model.resolveDuplicate(
                    conflict,
                    handling: .addNumber
                )
            }
            Button("Keep Both — Add Video ID") {
                model.resolveDuplicate(
                    conflict,
                    handling: .addVideoID
                )
            }
            Button("Skip This Download") {
                model.resolveDuplicate(
                    conflict,
                    handling: .skip
                )
            }
            Button("Cancel Download", role: .cancel) {
                model.resolveDuplicate(
                    conflict,
                    handling: nil
                )
            }
        } message: { conflict in
            Text(
                "\(conflict.desiredURL.lastPathComponent) already exists. Choose how Illucet should handle this output."
            )
        }
        .confirmationDialog(
            "Use cellular data?",
            isPresented: networkDialogPresented,
            titleVisibility: .visible,
            presenting: model.pendingNetworkAccessRequest
        ) { request in
            Button("Continue Once") {
                model.resolveNetworkAccess(
                    request,
                    choice: .continueOnce
                )
            }
            Button("Always Allow Cellular") {
                model.resolveNetworkAccess(
                    request,
                    choice: .alwaysAllow
                )
            }
            Button("Wait for Wi-Fi") {
                model.resolveNetworkAccess(
                    request,
                    choice: .waitForWiFi
                )
            }
            Button("Cancel Download", role: .destructive) {
                model.resolveNetworkAccess(
                    request,
                    choice: .cancel
                )
            }
        } message: { request in
            Text(
                "\(request.title) is ready to transfer over cellular. Choose whether this job may continue."
            )
        }
        .appAlertPresenter(model: model)
        .overlay {
            if model.presentsPastePermissionTip {
                FirstPasteTipView()
                    .environmentObject(model)
            }
        }
    }

    private var workspace: some View {
        TabView(selection: Binding(get: { model.selectedTab }, set: model.selectTab)) {
            Tab("Download", systemImage: AppTab.download.systemImage, value: AppTab.download) {
                DownloadView()
                    .padding(.bottom, usesFloatingBar && !keyboardVisible ? floatingBarHeight : 0)
                    .toolbar(usesFloatingBar ? .hidden : .automatic, for: .tabBar)
                    .accessibilityIdentifier("tab.download")
            }
            Tab("Queue", systemImage: AppTab.queue.systemImage, value: AppTab.queue) {
                QueueView()
                    .padding(.bottom, usesFloatingBar && !keyboardVisible ? floatingBarHeight : 0)
                    .toolbar(usesFloatingBar ? .hidden : .automatic, for: .tabBar)
                    .accessibilityIdentifier("tab.queue")
            }
            .badge(model.queueTabBadge.map { Text($0.nativeText) })
            Tab("History", systemImage: AppTab.history.systemImage, value: AppTab.history) {
                HistoryView()
                    .padding(.bottom, usesFloatingBar && !keyboardVisible ? floatingBarHeight : 0)
                    .toolbar(usesFloatingBar ? .hidden : .automatic, for: .tabBar)
                    .accessibilityIdentifier("tab.history")
            }
            Tab("Settings", systemImage: AppTab.settings.systemImage, value: AppTab.settings) {
                SettingsView()
                    .padding(.bottom, usesFloatingBar && !keyboardVisible ? floatingBarHeight : 0)
                    .toolbar(usesFloatingBar ? .hidden : .automatic, for: .tabBar)
                    .accessibilityIdentifier("tab.settings")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environment(\.symbolVariants, .none)
        .toolbar(usesFloatingBar ? .hidden : .automatic, for: .tabBar)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .overlay(alignment: .bottom) { floatingBar }
        .background(theme.background)
    }

    @ViewBuilder
    private var floatingBar: some View {
        if usesFloatingBar && !keyboardVisible {
            IllucetFloatingTabBar()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { floatingBarHeight = $0 }
        }
    }

    private var startupView: some View {
        ZStack {
            IllucetBackground()
            if let error = model.startupState.recoveryError {
                ScrollView {
                    EmptyStateView(
                        systemImage: "externaldrive.badge.exclamationmark",
                        title: "Your saved data is protected",
                        message: error.localizedDescription,
                        actionTitle: "Try Again",
                        action: model.retryStartupRecovery,
                        accessibilityPrefix: "startup.recovery"
                    )
                    .padding(.vertical, 32)
                }
                .defaultScrollAnchor(.center)
                .accessibilityIdentifier("app.recovery")
            } else {
                GeometryReader { geometry in
                    Image("IllucetLaunchBrand")
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .background(Color("LaunchBackground"))
                .ignoresSafeArea()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Opening Illucet")
                .accessibilityIdentifier("app.loading")
            }
        }
    }

    private var duplicateDialogPresented: Binding<Bool> {
        let requestID = model.pendingDuplicateConflict?.id
        return Binding(
            get: { model.pendingDuplicateConflict != nil },
            set: { presented in
                if !presented {
                    model.duplicateDialogDidDismiss(
                        requestID: requestID
                    )
                }
            }
        )
    }

    private var pendingShareRequest: Binding<SharePresentationRequest?> {
        Binding(
            get: { model.pendingShareRequest },
            set: { _ in }
        )
    }

    private var networkDialogPresented: Binding<Bool> {
        let requestID = model.pendingNetworkAccessRequest?.id
        return Binding(
            get: { model.pendingNetworkAccessRequest != nil },
            set: { presented in
                if !presented {
                    model.networkDialogDidDismiss(
                        requestID: requestID
                    )
                }
            }
        )
    }
}

private struct FilesFolderImporterModifier: ViewModifier {
    @ObservedObject var model: IllucetAppModel
    let source: FilesFolderPickerSource

    func body(content: Content) -> some View {
        folderPicker(content: content)
            .alert(
                aliasEditorTitle,
                isPresented: aliasEditorPresented
            ) {
                TextField("Folder alias", text: aliasDraft)
                    .accessibilityIdentifier("storage.filesFolderAliasField")
                Button(aliasSaveTitle) {
                    model.saveFilesFolderAlias()
                }
                Button(aliasCancelTitle, role: .cancel) {
                    model.cancelFilesFolderAliasEditing()
                }
            } message: {
                Text(aliasEditorMessage)
            }
    }

    @ViewBuilder
    private func folderPicker(content: Content) -> some View {
        if model.usesDeterministicFolderPicker {
            content.confirmationDialog(
                "Choose a Files folder",
                isPresented: isPresented,
                titleVisibility: .visible
            ) {
                if model.usesDocumentsFolderPickerFixture {
                    Button("Use Documents Folder") {
                        model.chooseFixtureDocumentsFolder()
                    }
                    Button("Use Different Folder") {
                        model.chooseFixtureAlternateFilesFolder()
                    }
                } else {
                    Button("Use Test Folder") {
                        model.chooseFixtureFilesFolder()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                brandedText("Select or reselect the folder Illucet may write to.")
            }
        } else {
            content.fileImporter(
                isPresented: isPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(URLs):
                    if let URL = URLs.first {
                        model.chooseFilesFolder(URL)
                    }
                case let .failure(error):
                    model.alert = .error(error)
                }
            }
        }
    }

    private var aliasEditorTitle: String {
        switch model.filesFolderAliasEditorMode {
        case .offer: "Name this Files folder?"
        case .edit: "Rename Files folder"
        case nil: "Rename Files folder"
        }
    }

    private var aliasEditorMessage: String {
        switch model.filesFolderAliasEditorMode {
        case .offer:
            "The provider resolved this location as Documents. You can assign a display-only alias such as VLC."
        case .edit, nil:
            "This name changes presentation only. Folder access and the saved destination stay unchanged."
        }
    }

    private var aliasSaveTitle: String {
        model.filesFolderAliasEditorMode == .offer ? "Save alias" : "Save"
    }

    private var aliasCancelTitle: String {
        model.filesFolderAliasEditorMode == .offer
            ? "Keep Documents"
            : "Cancel"
    }

    private var aliasEditorPresented: Binding<Bool> {
        Binding(
            get: { model.filesFolderAliasEditorMode != nil },
            set: { presented in
                if !presented {
                    Task { @MainActor in
                        await Task.yield()
                        model.cancelFilesFolderAliasEditing()
                    }
                }
            }
        )
    }

    private var aliasDraft: Binding<String> {
        Binding(
            get: { model.filesFolderAliasDraft },
            set: { model.updateFilesFolderAliasDraft($0) }
        )
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { model.filesFolderPickerSource == source },
            set: { presented in
                if presented {
                    model.requestFilesFolderPicker(from: source)
                } else {
                    model.dismissFilesFolderPicker(from: source)
                }
            }
        )
    }
}

private struct AppAlertPresenterModifier: ViewModifier {
    @ObservedObject var model: IllucetAppModel

    func body(content: Content) -> some View {
        content.alert(item: $model.alert) { alert in
            Alert(
                title: brandedText(alert.title, font: .headline),
                message: brandedText(alert.message, font: .body),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

private struct UnusedSpaceKeyboardDismissalModifier: ViewModifier {
    let identifier: String
    let isFocused: Bool
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .background {
                KeyboardDismissalObserver(isFocused: isFocused, dismiss: dismiss)
                    .accessibilityHidden(true)
            }
            // Exposing a transparent background as a separate accessibility
            // element breaks descendant hit testing after rotation on iOS 27.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}

/// Observe taps without participating in SwiftUI's control gesture arbitration.
/// In particular, a Form Section's simultaneous TapGesture can swallow a menu.
private struct KeyboardDismissalObserver: UIViewRepresentable {
    let isFocused: Bool
    let dismiss: () -> Void

    func makeUIView(context: Context) -> ObserverView { ObserverView() }
    func updateUIView(_ view: ObserverView, context: Context) {
        view.isObserving = isFocused
        view.dismissKeyboard = dismiss
    }
    static func dismantleUIView(_ view: ObserverView, coordinator: ()) { view.detach() }

    final class ObserverView: UIView, UIGestureRecognizerDelegate {
        var isObserving = false
        var dismissKeyboard: (() -> Void)?
        private weak var observedWindow: UIWindow?
        private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            isUserInteractionEnabled = false
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            observedWindow = window
        }
        func detach() {
            observedWindow?.removeGestureRecognizer(tap)
            observedWindow = nil
        }
        @objc private func tapped() {
            // Let the tapped control finish handling this event before focus
            // changes resize the form or bring the floating tab bar back.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isObserving else { return }
                self.dismissKeyboard?()
            }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard isObserving, window != nil, bounds.contains(touch.location(in: self)) else { return false }
            var target = touch.view
            while let view = target {
                if view is UITextField || view is UITextView { return false }
                target = view.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

extension View {
    func appAlertPresenter(model: IllucetAppModel) -> some View {
        modifier(AppAlertPresenterModifier(model: model))
    }

    func filesFolderImporter(
        model: IllucetAppModel,
        source: FilesFolderPickerSource
    ) -> some View {
        modifier(FilesFolderImporterModifier(model: model, source: source))
    }

    func dismissesKeyboardFromUnusedSpace(
        identifier: String,
        isFocused: Bool,
        dismiss: @escaping () -> Void
    ) -> some View {
        modifier(
            UnusedSpaceKeyboardDismissalModifier(
                identifier: identifier,
                isFocused: isFocused,
                dismiss: dismiss
            )
        )
    }
}
