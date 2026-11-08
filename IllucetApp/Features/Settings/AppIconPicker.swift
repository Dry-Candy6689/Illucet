import SwiftUI
import UIKit

enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    case blue = "Blue", orange = "Orange", purple = "Purple", pink = "Pink"
    var id: String { rawValue }
    var title: String { self == .blue ? "Light blue" : rawValue }
    var alternateName: String? { self == .blue ? nil : "AppIcon" + rawValue }
}

@MainActor
final class AppIconController: ObservableObject {
    @Published private(set) var selected: AppIconChoice
    @Published private(set) var isChanging = false
    @Published var errorMessage: String?
    let supported = UIApplication.shared.supportsAlternateIcons

    init() { selected = Self.currentChoice }

    private static var currentChoice: AppIconChoice {
        AppIconChoice.allCases.first { $0.alternateName == UIApplication.shared.alternateIconName } ?? .blue
    }

    func select(_ choice: AppIconChoice) async {
        guard supported, !isChanging, choice != selected else { return }
        isChanging = true
        defer { selected = Self.currentChoice; isChanging = false }
        do { try await UIApplication.shared.setAlternateIconName(choice.alternateName) }
        catch { errorMessage = error.localizedDescription }
    }
}

struct AppIconPicker: View {
    @Environment(\.illucetPalette) private var theme
    @StateObject private var icons = AppIconController()

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(AppIconChoice.allCases) { choice in
                Button {
                    Task { await icons.select(choice) }
                } label: {
                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            preview(choice, "Light")
                            preview(choice, "Dark")
                        }
                        HStack(spacing: 5) {
                            Text(choice.title).font(.subheadline.weight(.medium))
                            if icons.selected == choice {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.foregroundAccent)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .padding(.vertical, 8)
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(icons.selected == choice ? theme.foregroundAccent : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(!icons.supported || icons.isChanging)
                .accessibilityLabel(choice.title)
                .accessibilityValue(icons.selected == choice ? "Selected" : "")
                .accessibilityIdentifier("interface.icon.\(choice.rawValue.lowercased())")
            }
        }
        .alert("Couldn’t change app icon", isPresented: Binding(
            get: { icons.errorMessage != nil }, set: { if !$0 { icons.errorMessage = nil } })) {
            Button("OK", role: .cancel) { icons.errorMessage = nil }
        } message: { Text(icons.errorMessage ?? "") }
    }

    private func preview(_ choice: AppIconChoice, _ appearance: String) -> some View {
        Image("IconPreview" + choice.rawValue + appearance)
            .resizable().scaledToFit().frame(maxWidth: 48, maxHeight: 48)
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }
}
