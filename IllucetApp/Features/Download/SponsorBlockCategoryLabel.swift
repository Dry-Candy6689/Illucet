import SwiftUI

// Official SponsorBlock English descriptions, translation revision
// 166548e90223a11c57713439080c1903b8853bd6. Attribution: docs/Licenses.md.
extension SponsorBlockCategory {
    var explanation: String {
        switch self {
        case .sponsor: "Paid promotion, paid referrals and direct advertisements. Not for self-promotion or free shoutouts to causes/creators/websites/products they like."
        case .selfPromotion: "Similar to \"sponsor\" except for unpaid or self promotion. This includes sections about merchandise, donations, or information about who they collaborated with."
        case .interaction: "When there is a short reminder to like, subscribe or follow them in the middle of content. If it is long or about something specific, it should be under self promotion instead."
        case .highlight: "The part of the video that most people are looking for. Similar to \"Video starts at x\" comments."
        case .intro: "An interval without actual content. Could be a pause, static frame, repeating animation. This should not be used for transitions containing information."
        case .outro: "Credits or when the YouTube endcards appear. Not for conclusions with information."
        case .preview: "Collection of clips that show what is coming up in in this video or other videos in a series where all information is repeated later in the video."
        case .hook: "Narrated trailers for the upcoming video, greetings and goodbyes. This should not skip conclusions with information."
        case .filler: "Tangential scenes or jokes that are not required to understand the main content of the video. This should not include segments providing context or background details. This is a very aggressive category meant for when you aren't in the mood for \"fun\"."
        }
    }
}

struct SponsorBlockCategoryLabel: View {
    let category: SponsorBlockCategory
    @State private var showsExplanation = false
    var body: some View {
        Button { showsExplanation = true } label: {
            Text(category.title).font(.subheadline).lineLimit(1).minimumScaleFactor(0.75)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.title)
        .accessibilityHint("Explain this SponsorBlock category")
        .accessibilityIdentifier("sponsorblock.help.\(category.rawValue)")
        .popover(isPresented: $showsExplanation) {
            VStack(alignment: .leading, spacing: 10) {
                Text(category.title).font(.headline)
                Text(category.explanation).font(.subheadline)
            }
            .padding(18)
            .frame(idealWidth: 300, maxWidth: 330)
            .presentationCompactAdaptation(.popover)
            .accessibilityAction(.escape) { showsExplanation = false }
        }
    }
}
