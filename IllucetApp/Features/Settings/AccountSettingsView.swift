import SwiftUI
import WebKit

extension IllucetAppModel {
    func refreshAccounts() async {
        do { accountProfiles = try await runtime.accounts.profiles() }
        catch { alert = .error(error) }
    }

    func removeAccount(_ id: UUID) async {
        do {
            try await runtime.accounts.remove(id)
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
        VStack(alignment: .leading, spacing: 6) {
            Picker("YouTube account", selection: $model.selectedAccountID) {
                Text("Without an account").tag(nil as UUID?)
                ForEach(model.accountProfiles) { profile in
                    Text(profile.name + (profile.expired ? " — sign in again" : ""))
                        .tag(Optional(profile.id))
                }
                if let id = model.selectedAccountID, !model.accountProfiles.contains(where: { $0.id == id }) {
                    Text("Removed account — choose another").tag(Optional(id))
                }
            }.disabled(model.isAnalyzing).accessibilityIdentifier("accounts.selection")
            NavigationLink("Manage YouTube accounts") { AccountSettingsView() }
                .font(.caption)
        }
    }
}

struct AccountBindingLabel: View {
    @EnvironmentObject private var model: IllucetAppModel
    let accountID: UUID?
    var body: some View {
        let profile = model.accountProfiles.first { $0.id == accountID }
        Label(accountID == nil ? "Without a YouTube account" :
            "YouTube account: " + (profile?.name ?? "Removed account"),
              systemImage: "person.crop.circle")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct AccountSettingsView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @State private var importing = false
    @State private var signingIn = false
    @State private var removing: AccountProfile?
    var body: some View {
        List {
            Section {
                ForEach(model.accountProfiles) { profile in
                    VStack(alignment: .leading) {
                        Text(profile.name)
                        if profile.expired { Text("Sign in again to save a new session").font(.caption).foregroundStyle(.secondary) }
                        Button(role: .destructive) { removing = profile } label: { brandedText("Remove from Illucet") }
                            .font(.caption)
                    }
                }
                Button("Import cookie file") { importing = true }
                Button("Sign in to YouTube") { signingIn = true }
                    .accessibilityIdentifier("accounts.signIn")
            } footer: {
                Text("Sessions are saved securely on this device. Removal stops this account’s active downloads and removes its saved session here; it does not sign you out of Google elsewhere. Expired sessions require a new sign-in and new downloads.")
            }
        }
        .navigationTitle("YouTube accounts")
        .task { await model.refreshAccounts() }
        .sheet(isPresented: $importing) { CookieImportView().environmentObject(model) }
        .sheet(isPresented: $signingIn) {
            AccountSignInView().environmentObject(model)
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
            .navigationTitle("Sign in to YouTube").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save account") { Task { await save() } }.disabled(saving)
                        .accessibilityIdentifier("accounts.save")
                }
            }
            .disabled(saving).interactiveDismissDisabled(saving)
            .task {
                name = "YouTube account \(model.accountProfiles.count + 1)"
                if !model.fixtureMode { session.open() }
            }
            .onDisappear { Task { await session.clear() } }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let cookies = await session.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let records = try YouTubeAccountCookie.snapshot(cookies)
            let id = try await model.runtime.accounts.add(name: name, cookies: records)
            model.selectedAccountID = id
            await model.refreshAccounts()
            dismiss()
        } catch let error as AccountError {
            failure = error.localizedDescription
        } catch {
            failure = "The account could not be saved securely. Try again."
        }
    }
}
