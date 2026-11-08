import SwiftUI
import UIKit

struct LinkSettingsView: View {
    @State private var showsHelp = false
    @EnvironmentObject private var model: IllucetAppModel
    private var preferences: Binding<ShortcutPreferences> {
        Binding(get: { model.settings.shortcutPreferences }, set: { model.settings.shortcutPreferences = $0 })
    }
    private var installURL: URL? {
        Bundle.main.url(forResource: "Download with Illucet", withExtension: "shortcut")
    }
    var body: some View {
        ScrollViewReader { scroll in
        Form {
            Section("Shortcut") {
                if let installURL {
                    Button {
                        Task {
                            if !(await UIApplication.shared.open(installURL, options: [:])) {
                                model.alert = AppAlert(title: "Couldn’t open Shortcuts", message: "Open the Shortcuts app once, then try Get Illucet shortcut again.")
                            }
                        }
                    } label: { brandedText("Get Illucet shortcut") }
                        .accessibilityIdentifier("shortcuts.install")
                } else {
                    Text("The shortcut file is unavailable.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("When run") {
                Picker("Action", selection: preferences.behavior) {
                    ForEach(ShortcutBehavior.allCases) { Text($0.rawValue).tag($0) }
                }.accessibilityIdentifier("shortcuts.action")
                Picker("Download settings", selection: preferences.preferredPresetID) {
                    Text("Current download defaults").tag(UUID?.none)
                    ForEach(model.quickStartPresets) { Text($0.name).tag(Optional($0.id)) }
                    if let selected = preferences.wrappedValue.preferredPresetID,
                       !model.quickStartPresets.contains(where: { $0.id == selected }) {
                        Text("Unavailable preset — choose another").tag(Optional(selected))
                    }
                }
            }
            DownloadScreenSettingsSection()
                .id("downloadScreens")
        }
        .task(id: model.highlightsDownloadScreens) {
            guard model.highlightsDownloadScreens else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                withAnimation { scroll.scrollTo("downloadScreens", anchor: .center) }
                try await Task.sleep(for: .seconds(2.5))
                model.highlightsDownloadScreens = false
            } catch { /* Leaving this page cancels its temporary spotlight. */ }
        }
        .onDisappear { model.highlightsDownloadScreens = false }
        .settingsFormBackground()
        .navigationTitle("Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsHelp = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("About Shortcuts")
                    .accessibilityIdentifier("shortcuts.info")
            }
        }
        .sheet(isPresented: $showsHelp) {
            NavigationStack {
                List {
                    brandedText("Get Illucet shortcut opens Add Shortcut in Shortcuts. Choose Download with Illucet when sharing a YouTube link. If missing, enable Show in Share Sheet in the shortcut’s Details.")
                    brandedText("Download immediately starts without opening Illucet. iOS may require you to reopen the app to finish processing; progress is kept.")
                    brandedText("The download-screen switches also apply to downloads started inside Illucet. Home presets keep their own confirmation choices.")
                }
                .navigationTitle("About Shortcuts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsHelp = false } } }
            }
        }
        }
    }
}

struct ClipboardSettingsView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @State private var explainsClipboard = false

    private var preferences: Binding<ClipboardPreferences> {
        Binding(get: { model.settings.clipboard ?? ClipboardPreferences() }, set: { model.settings.clipboard = $0 })
    }
    private var automaticChecks: Binding<Bool> {
        Binding(get: { preferences.wrappedValue.checksAutomatically }, set: { enabled in
            if enabled && !preferences.wrappedValue.explained { explainsClipboard = true }
            else { setAutomaticChecks(enabled) }
        })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Check copied links automatically", isOn: automaticChecks)
                Picker("When a copied link is found", selection: preferences.behavior) {
                    ForEach(ClipboardBehavior.allCases) { Text($0.rawValue).tag($0) }
                }.disabled(!automaticChecks.wrappedValue)
                Toggle("Replace existing URL", isOn: preferences.replacesExistingURL)
                    .disabled(!automaticChecks.wrappedValue)
                    .accessibilityIdentifier("clipboard.replace")
            } header: {
                Text("When Illucet opens or returns")
            } footer: {
                Text("Replacement applies your chosen action when the Download field already has a different YouTube link.")
            }
            Section("iOS paste permission") { PasteSettingsButton() }
        }
        .settingsFormBackground()
        .navigationTitle("App opening & clipboard")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Allow automatic clipboard checks?", isPresented: $explainsClipboard) {
            Button("Enable checks") {
                preferences.wrappedValue.explained = true
                setAutomaticChecks(true)
            }
            Button("Keep off", role: .cancel) { }
        } message: {
            brandedText("Illucet checks for copied YouTube links when you open or return to the app. You choose how it handles new links.")
        }
    }

    private func setAutomaticChecks(_ enabled: Bool) {
        var value = preferences.wrappedValue
        value.enabled = enabled
        value.checkAtStartup = enabled
        preferences.wrappedValue = value
        if enabled { model.lastAutomaticClipboardChange = nil }
        else { model.clipboardSuggestion = nil }
    }
}

struct HomeQuickStartSettingsView: View {
    @EnvironmentObject private var model: IllucetAppModel
    var body: some View {
        List {
            QuickStartPresetSections()
        }
        .settingsFormBackground()
        .navigationTitle("Home Quick Start")
        .navigationBarBackButtonHidden(model.pipGuideStep != nil)
        .navigationBarTitleDisplayMode(.inline)

    }
}

private struct PasteSettingsButton: View {
    var body: some View {
        Button("Open iOS paste settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }
}
