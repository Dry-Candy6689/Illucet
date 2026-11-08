import SwiftUI
import UIKit

struct FirstPasteTipView: View {
    @EnvironmentObject private var model: IllucetAppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()
                .onTapGesture { model.dismissPastePermissionTip() }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) {
                Text("Make pasting easier")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("For automatic pasting without repeated permission prompts, open [iOS Settings](app-settings:) and set **Paste from Other Apps** to **Allow**.")
                    .font(.subheadline)
                    .tint(.blue)
                    .environment(\.openURL, OpenURLAction { _ in
                        Task { @MainActor in
                            model.dismissPastePermissionTip()
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        return .handled
                    })
                    .accessibilityIdentifier("clipboard.tip.message")
                brandedText("Automatic checks are controlled in Illucet’s App opening & clipboard settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Got it") { model.dismissPastePermissionTip() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("clipboard.tip.dismiss")
            }
            .padding(22)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 24)
            .shadow(radius: 20)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("clipboard.tip")
        }
        .onAppear { model.pastePermissionTipDidAppear() }
    }
}
