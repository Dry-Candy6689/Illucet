import SwiftUI
import UniformTypeIdentifiers

struct CookieImportView: View {
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Imported YouTube account"
    @State private var choosing = false
    @State private var cookies: [YouTubeAccountCookie] = []
    @State private var failure: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    brandedText("Cookie files grant access to your signed-in session. Import only your own file from a browser you trust. Prefer Illucet’s built-in sign-in when available.")
                    Text("Only YouTube cookies are imported. The session stays in this device’s Keychain; cookie values are never shown in diagnostics. The original file stays where you selected it—delete that file yourself when you no longer need it.")
                }
                Section("Netscape cookie file") {
                    TextField("Account label", text: $name)
                    Button("Choose cookie file") { choosing = true }.accessibilityIdentifier("accounts.chooseCookieFile")
                    if !cookies.isEmpty { Text("Validated \(cookies.count) YouTube cookies. Save to create the account.") }
                    if let failure { Text(failure).foregroundStyle(.red) }
                    Button("Save imported account") { Task { await save() } }
                        .disabled(cookies.isEmpty || saving)
                }
            }
            .navigationTitle("Import account")
            .toolbar { Button("Cancel") { dismiss() }.disabled(saving) }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.plainText, .data]) { result in
                cookies = []
                failure = nil
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true, let size = values.fileSize,
                          size <= CookieFileImport.maximumBytes else { throw AccountError.invalidSession }
                    // Bounded read also protects against a file growing after the size check.
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    cookies = try CookieFileImport.parse(handle.read(upToCount: CookieFileImport.maximumBytes + 1) ?? Data())
                } catch { failure = "This file does not contain a valid, current YouTube session in Netscape format." }
            }
            .onDisappear { cookies = [] }
        }
    }
    private func save() async {
        saving = true
        defer { saving = false }
        do {
            model.selectedAccountID = try await model.runtime.accounts.add(name: name, cookies: cookies)
            cookies = []
            await model.refreshAccounts()
            dismiss()
        } catch let error as AccountError { failure = error.localizedDescription }
        catch { failure = "The imported session could not be saved securely." }
    }
}
