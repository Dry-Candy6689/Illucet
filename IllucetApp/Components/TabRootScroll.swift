import SwiftUI
import UIKit

/// Each tab keeps its own binding for the lifetime of the workspace. A request
/// starts empty and is consumed once, so mounting a view never replays a reset.
@MainActor
final class TabScrollState: ObservableObject {
    struct Request: Equatable {
        let id = UUID()
        var animated: Bool
    }
    @Published var position = ScrollPosition()
    @Published var request: Request?

    func scrollToTop(animated: Bool) { request = Request(animated: animated) }
}

private struct TabRootScroll: ViewModifier {
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var state: TabScrollState
    let tab: AppTab
    var scrollToTop: (() -> Void)?

    func body(content: Content) -> some View {
        Group {
            if scrollToTop == nil { content.scrollPosition($state.position) }
            else { content }
        }
        .onChange(of: state.request, initial: true) { _, _ in consumeRequest() }
        .onChange(of: model.selectedTab) { _, _ in consumeRequest() }
    }

    private func consumeRequest() {
        guard model.selectedTab == tab, let request = state.request else { return }
        state.request = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        // Edge scrolling includes content margins and the navigation safe area;
        // aligning the hero's frame instead cuts off its top padding.
        withAnimation(request.animated && !reduceMotion ? .easeInOut(duration: 0.25) : nil) {
            if let scrollToTop { scrollToTop() }
            else { state.position.scrollTo(edge: .top) }
        }
    }
}

extension View {
    func tabRootScroll(_ tab: AppTab, model: IllucetAppModel, scrollToTop: (() -> Void)? = nil) -> some View {
        modifier(TabRootScroll(state: model.tabScrollStates[tab]!, tab: tab, scrollToTop: scrollToTop))
    }
}
