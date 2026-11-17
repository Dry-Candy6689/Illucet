import SwiftUI
import WebKit

extension IllucetAppModel {
    func preferredAccountID(for site: MediaSite) -> UUID? {
        (site == .youtube ? selectedAccountID : nil) ?? settings.siteDefaults?[site.rawValue]?.accountID
    }

    func selectPreferredAccount(_ id: UUID?, for site: MediaSite) {
        if site == .youtube { selectedAccountID = id }
        var defaults = settings.siteDefaults ?? [:]
        var value = defaults[site.rawValue] ?? .init()
        value.accountID = id
        defaults[site.rawValue] = value
        settings.siteDefaults = defaults
        settingsChanged()
    }

    func refreshAccounts() async {
        do { accountProfiles = try await runtime.accounts.profiles() }
        catch { alert = .error(error) }
    }

    func removeAccount(_ id: UUID) async {
        do {
            try await runtime.accounts.remove(id)
            await YouTubeTokenBroker.shared.invalidateAccount(id)
            for job in await coordinator.currentJobs() where job.configuration.accountID == id && !job.state.isTerminal {
                await coordinator.cancel(job.id)
            }
            // Keep a removed selection visible until the user explicitly changes it.
            await refreshAccounts()
        } catch { alert = .error(error) }
    }
}

struct AccountSelectionView: View {
    @EnvironmentObject private var model: IllucetAppModel
    var body: some View {
        let site = LinkIntakePolicy.supportedURL(model.URLText).flatMap(MediaSite.recognize) ?? .youtube
        let selection = Binding(get: { model.preferredAccountID(for: site) }, set: { model.selectPreferredAccount($0, for: site) })
        VStack(alignment: .leading, spacing: 6) {
            Picker("Preferred \(site.name) account", selection: selection) {
                Text("None").tag(nil as UUID?)
                ForEach(model.accountProfiles.filter { $0.site == site }) { profile in
                    Text(profile.name + (profile.expired ? " — sign in again" : ""))
                        .tag(Optional(profile.id))
                }
                if let id = selection.wrappedValue, !model.accountProfiles.contains(where: { $0.id == id }) {
                    Text("Removed account — choose another").tag(Optional(id))
                }
            }.disabled(model.isAnalyzing).accessibilityIdentifier("accounts.selection")
            NavigationLink("Manage accounts") { AccountSettingsView() }
                .font(.caption)
            Text("Automatic uses a guest session first.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AccountBindingLabel: View {
    @EnvironmentObject private var model: IllucetAppModel
    let accountID: UUID?
    var body: some View {
        let profile = model.accountProfiles.first { $0.id == accountID }
        Label(accountID == nil ? "Guest session" :
            "Preferred account: " + (profile?.name ?? "Removed account"),
              systemImage: "person.crop.circle")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct AccountSettingsView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @State private var adding: MediaSite?
    @State private var importing: MediaSite?
    @State private var signingIn: MediaSite?
    private var sites: [MediaSite] {
        MediaSite.accountSites + MediaSite.allCases.filter { site in
            !MediaSite.accountSites.contains(site) && model.accountProfiles.contains { $0.site == site }
        }
    }
    var body: some View {
        List {
            Section {
                ForEach(sites) { site in
                    HStack(spacing: 12) {
                        NavigationLink {
                            SiteAccountSettingsView(site: site)
                        } label: {
                            HStack(spacing: 12) {
                                Image("SiteLogo-\(site.rawValue)").renderingMode(.template).resizable().scaledToFit()
                                    .frame(width: 26, height: 26).foregroundStyle(.primary).accessibilityHidden(true)
                                Text(site.name)
                                Spacer(minLength: 4)
                                Text(status(site)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("accounts.site.\(site.rawValue)")
                        Button { adding = site } label: {
                            Image(systemName: "plus.circle.fill").font(.title3).frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                            .buttonStyle(.borderless).accessibilityLabel("Add \(site.name) account")
                            .accessibilityIdentifier("accounts.add.\(site.rawValue)")
                    }
                }
            } footer: {
                Text("Public downloads start as a guest. An account is tried only when access requires it. Sessions stay in this device’s Keychain; each website has its own preferred account.")
            }
        }
        .navigationTitle("Accounts")
        .task { await model.refreshAccounts() }
        .confirmationDialog("Add \(adding?.name ?? "website") account", isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } }), titleVisibility: .visible) {
            Button("Browser sign-in") { signingIn = adding; adding = nil }
            Button("Import cookies") { importing = adding; adding = nil }
            Button("Cancel", role: .cancel) { adding = nil }
        }
        .sheet(item: $importing) { CookieImportView(site: $0).environmentObject(model) }
        .sheet(item: $signingIn) { AccountSignInView(site: $0).environmentObject(model) }
    }
    private func status(_ site: MediaSite) -> String {
        let profiles = model.accountProfiles.filter { $0.site == site }
        let connected = profiles.filter { $0.verified && !$0.expired }.count
        if connected > 0 { return connected == 1 ? "Connected" : "Connected \(connected)" }
        if profiles.contains(where: { !$0.expired }) { return "Saved \(profiles.filter { !$0.expired }.count)" }
        return profiles.isEmpty ? "" : "Sign in again"
    }
}

struct SiteAccountSettingsView: View {
    let site: MediaSite
    @EnvironmentObject private var model: IllucetAppModel
    @State private var importing = false
    @State private var signingIn = false
    @State private var removing: AccountProfile?
    @State private var checking: UUID?
    private var preferred: Binding<UUID?> {
        Binding(get: { model.preferredAccountID(for: site) }, set: { model.selectPreferredAccount($0, for: site) })
    }
    private var policy: Binding<AccountAccessPolicy> {
        Binding(get: { model.settings.extractionPreferences(for: site).accountAccess ?? .automatic }, set: { policy in
            var defaults = model.settings.siteDefaults ?? [:]
            var value = defaults[site.rawValue] ?? .init(); value.accountAccess = policy
            defaults[site.rawValue] = value; model.settings.siteDefaults = defaults
            model.settingsChanged()
        })
    }
    var body: some View {
        List {
            Section {
                Picker("Account use", selection: policy) {
                    ForEach(AccountAccessPolicy.allCases) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("accounts.policy")
                Picker("Preferred account", selection: preferred) {
                    Text("None").tag(UUID?.none)
                    ForEach(model.accountProfiles.filter { $0.site == site }) { Text($0.name).tag(Optional($0.id)) }
                    if let id = preferred.wrappedValue, !model.accountProfiles.contains(where: { $0.id == id }) {
                        Text("Removed account — choose another").tag(Optional(id))
                    }
                }
            } footer: {
                Text("Automatic tries this account only after the website requires sign-in or restricted access. It never tries your other accounts. Guest only never sends your saved session.")
            }
            Section {
                ForEach(model.accountProfiles.filter { $0.site == site }) { profile in
                    VStack(alignment: .leading) {
                        Text(profile.name)
                        Text(profile.expired ? "Sign in again" : profile.verified ? "Connected" : "Saved — not yet verified").font(.caption).foregroundStyle(.secondary)
                        Button(checking == profile.id ? "Checking…" : "Check connection") {
                            checking = profile.id
                            Task {
                                defer { checking = nil }
                                do { try await model.runtime.verifyAccount(id: profile.id, site: site); await model.refreshAccounts() }
                                catch { model.alert = .error(error) }
                            }
                        }.font(.caption).disabled(checking != nil)
                        Button(role: .destructive) { removing = profile } label: { brandedText("Remove from Illucet") }
                            .font(.caption)
                    }
                }
                Button("Import cookies") { importing = true }
                Button("Sign in to \(site.name)") { signingIn = true }
                    .accessibilityIdentifier("accounts.signIn")
            } footer: {
                Text("Sessions are saved securely on this device and isolated by website. Some websites reject embedded sign-in or use sessions that cannot be imported. Saving cookies does not prove the site will accept them for a download.")
            }
            if site == .youtube {
                Section("PO tokens") { NavigationLink("Local token generation") { YouTubeTokenSettingsView() } }
            }
        }
        .navigationTitle(site.name)
        .task { await model.refreshAccounts() }
        .sheet(isPresented: $importing) { CookieImportView(site: site).environmentObject(model) }
        .sheet(isPresented: $signingIn) {
            AccountSignInView(site: site).environmentObject(model)
        }
        .confirmationDialog("Remove this saved account and stop its active downloads?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button(role: .destructive) {
                if let id = removing?.id { Task { await model.removeAccount(id) } }
                removing = nil
            } label: { brandedText("Remove from Illucet") }
        }
    }
}

struct AccountSignInView: View {
    var site: MediaSite = .youtube
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = YouTubeSignInSession()
    @State private var name = "YouTube account"
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                TextField("Account label", text: $name).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("accounts.label")
                Text("Sign in below, then save this session on your device.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(session.location).font(.caption)
                if session.status.hasPrefix("Page could not load") {
                    Text(session.status).font(.caption).foregroundStyle(.secondary)
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                YouTubeSignInBrowser(session: session).id(ObjectIdentifier(session.webView))
            }
            .padding(.horizontal, 12)
            .navigationTitle("Sign in to \(site.name)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save account") { Task { await save() } }.disabled(saving)
                        .accessibilityIdentifier("accounts.save")
                }
            }
            .disabled(saving).interactiveDismissDisabled(saving)
            .task {
                name = "\(site.name) account \(model.accountProfiles.count + 1)"
                if !model.fixtureMode { session.open(site: site) }
            }
            .onDisappear { Task { await session.clear() } }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let cookies = await session.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let records = try YouTubeAccountCookie.snapshot(cookies, site: site)
            let id = try await model.runtime.accounts.add(name: name, cookies: records, site: site)
            if model.preferredAccountID(for: site) == nil { model.selectPreferredAccount(id, for: site) }
            await model.refreshAccounts()
            dismiss()
        } catch let error as AccountError {
            failure = site == .youtube ? error.localizedDescription : "This website did not provide a usable session. Try importing your own cookie file or download public media without an account."
        } catch {
            failure = "The account could not be saved securely. Try again."
        }
    }
}
