import SwiftUI
import UIKit

struct LicensesView: View {
    @EnvironmentObject private var model: IllucetAppModel

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image("IllucetLaunchBrand").resizable().scaledToFit()
                        .frame(width: 72, height: 72).accessibilityHidden(true)
                    brandedText(AppIdentity.displayName)
                        .font(.title2.bold())
                    CopyableVersionRow(title: "Version", version:
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section("Embedded components") {
                versionRow(
                    "CPython",
                    model.extractionVersions?.python ?? DependencyVersions.python,
                    "Python Software Foundation License"
                )
                versionRow(
                    "yt-dlp",
                    model.updateStatus.activeYTDLPVersion,
                    "The Unlicense"
                )
                versionRow(
                    "yt-dlp EJS",
                    model.updateStatus.activeEJSVersion,
                    "The Unlicense"
                )
                versionRow(
                    "QuickJS-ng",
                    DependencyVersions.quickJS,
                    "MIT"
                )
                versionRow(
                    "FFmpeg",
                    String(cString: illucet_ffmpeg_version()),
                    "LGPL 2.1+ configuration"
                )
                versionRow("LAME", DependencyVersions.lame, "LGPL 2.0")
                if let version = model.extractionVersions?.openSSL {
                    versionRow("OpenSSL", version, "Apache 2.0")
                }
                versionRow("certifi", model.updateStatus.activeCertifiVersion ?? DependencyVersions.certifi, "MPL 2.0")
            }

            Section("SponsorBlock") {
                Link("Category descriptions · SponsorBlock contributors · GPL-3.0", destination: URL(string: "https://github.com/ajayyy/SponsorBlock/blob/master/LICENSE")!)
                Link("SponsorBlock logo · munadikieh", destination: URL(string: "https://github.com/ajayyy/SponsorBlock")!)
                Link("Original shield icon", destination: URL(string: "https://github.com/ajayyy/SponsorBlock/blob/master/public/icons/IconSponsorBlocker256px.png")!)
                Link("Logo licensing", destination: URL(string: "https://commons.wikimedia.org/wiki/File:SponsorBlockLogo.png")!)
            }
        }
        .task {
            guard !model.fixtureMode else { return }
            await model.refreshExtractorStatus()
            if let extractor = try? await model.runtime.extractor() {
                model.extractionVersions = try? await extractor.versions()
            }
        }
        .settingsFormBackground()
        .navigationTitle("About & licenses")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func versionRow(
        _ name: String,
        _ version: String,
        _ license: String
    ) -> some View {
        CopyableVersionRow(title: name, version: version, footnote: license)
    }
}
