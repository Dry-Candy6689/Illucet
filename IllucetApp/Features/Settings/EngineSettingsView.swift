import SwiftUI

struct EngineSettingsView: View {
    @EnvironmentObject private var model: IllucetAppModel
    private var preferences: Binding<EnginePreferences> {
        Binding(get: { model.settings.engines ?? .init() }, set: { model.settings.engines = $0; model.settingsChanged() })
    }
    var body: some View {
        Form {
            Section {
                Picker("Download engine", selection: preferences.download) {
                    ForEach(DownloadEngineChoice.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("engines.download")
            } footer: { Text("Automatic uses Native for direct transfers and yt-dlp for supported complex delivery. yt-dlp needs in-app execution and may restart an incomplete transfer after suspension.") }
            if preferences.download.wrappedValue == .aria2 {
                Section { Text(Aria2TransferPolicy.explanation).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                Picker("JavaScript solver", selection: preferences.javaScript) {
                    ForEach(JavaScriptSolverChoice.allCases) { Text($0.label).tag($0) }
                }
                Picker("YouTube client", selection: preferences.youtubeClient) {
                    Text("Automatic").tag("default")
                    Text("Safari web").tag("web_safari")
                    Text("Web").tag("web")
                    Text("Mobile web").tag("mweb")
                    Text("iOS").tag("ios")
                    Text("TV").tag("tv")
                }
            } header: { Text("YouTube compatibility") }
            footer: { Text("Automatic prefers QuickJS. Client choices can change available formats; some need a session or an on-device PO-token provider. Cookies and PO tokens serve different purposes.") }
            Section {
                Toggle("Remove location & camera metadata", isOn: preferences.removeImageMetadata)
            } header: { Text("Images") }
            footer: { Text("Creates a private copy when the source format supports it. Original images and animation are preserved when this is off.") }
            Section("Per-site defaults") {
                ForEach(MediaSite.allCases) { site in
                    NavigationLink { SiteDefaultsView(site: site) } label: { SiteSourceLabel(site: site) }
                }
            }
            Section {
                NavigationLink("YouTube PO tokens") { YouTubeTokenSettingsView() }
            }
        }
        .navigationTitle("Engines & compatibility")
    }
}

struct YouTubeTokenSettingsView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @State private var testing = false
    @State private var result: String?
    private var mode: Binding<YouTubeTokenMode> {
        Binding(get: { model.settings.engines?.poTokens ?? .automatic }, set: {
            var settings = model.settings.engines ?? .init()
            settings.poTokens = $0
            model.settings.engines = settings
            model.settingsChanged()
        })
    }
    var body: some View {
        Form {
            Section {
                Picker("Generate tokens", selection: mode) {
                    ForEach(YouTubeTokenMode.allCases) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("tokens.mode")
                Button(testing ? "Testing…" : "Test local generator") {
                    testing = true
                    Task {
                        defer { testing = false }
                        do {
                            let first = YouTubeProofRequest(client: "MWEB", context: "gvs", videoID: "dQw4w9WgXcQ", binding: "dQw4w9WgXcQ", sessionBinding: "diagnostic")
                            let next = YouTubeProofRequest(client: "MWEB", context: "gvs", videoID: "aqz-KE-bpKQ", binding: "aqz-KE-bpKQ", sessionBinding: "diagnostic")
                            let start = ContinuousClock.now
                            let initial = try await YouTubeTokenBroker.shared.token(for: first, scope: nil)
                            let warm = try await YouTubeTokenBroker.shared.token(for: next, scope: nil)
                            let elapsed = start.duration(to: .now).components
                            result = "Generated two local tokens in \(elapsed.seconds)s. Session setup \(initial.setupMilliseconds) ms. Next token \(warm.mintMilliseconds) ms."
                        } catch { result = error.localizedDescription }
                    }
                }.disabled(testing).accessibilityIdentifier("tokens.test")
                if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("YouTube may require a proof token for some streams. Illucet generates it on this device using WebKit. A proof token does not sign in or grant access to private media.")
            }
        }.navigationTitle("YouTube PO tokens")
    }
}

private struct SiteDefaultsView: View {
    @EnvironmentObject private var model: IllucetAppModel
    let site: MediaSite
    private var defaults: Binding<SiteDownloadDefaults> {
        Binding(get: { model.settings.siteDefaults?[site.rawValue] ?? .init() }, set: {
            var values = model.settings.siteDefaults ?? [:]; values[site.rawValue] = $0
            model.settings.siteDefaults = values; model.settingsChanged()
        })
    }
    var body: some View {
        Form {
            Section { SiteSourceLabel(site: site) }
            Picker("Download engine", selection: defaults.engine) {
                Text("Use general setting").tag(DownloadEngineChoice?.none)
                ForEach(DownloadEngineChoice.allCases) { Text($0.label).tag(Optional($0)) }
            }
            if defaults.engine.wrappedValue == .aria2 {
                Text(Aria2TransferPolicy.explanation).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Preferred account", selection: Binding(get: { model.preferredAccountID(for: site) }, set: { model.selectPreferredAccount($0, for: site) })) {
                Text("None").tag(UUID?.none)
                ForEach(model.accountProfiles.filter { $0.site == site }) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Preset", selection: defaults.preset) {
                Text("Best available").tag("best")
                Text("Compatible MP4").tag("compatible")
            }
            Text("Explicit download choices override these defaults. Images use their original format.")
                .font(.caption).foregroundStyle(.secondary)
        }.navigationTitle(site.name)
    }
}
