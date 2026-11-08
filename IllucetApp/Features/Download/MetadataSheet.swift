import SwiftUI

struct MetadataSheet: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel
    @Environment(\.dismiss) private var dismiss
    let metadata: MediaMetadata

    var body: some View {
        NavigationStack {
            ZStack {
                IllucetBackground()
                ScrollView {
                    VStack(spacing: 20) {
                        artwork
                        titleBlock
                        facts
                        qualitySummary
                        if !metadata.chapters.isEmpty {
                            chapterSummary
                        }
                        if let description = metadata.description,
                           !description.isEmpty {
                            descriptionBlock(description)
                        }
                        Button {
                            model.openConfiguration()
                        } label: {
                            Label(
                                "Choose download options",
                                systemImage: "slider.horizontal.3"
                            )
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .accessibilityIdentifier("metadata.configure")
                    }
                    .padding(18)
                    .padding(.bottom, 26)
                }
            }
            .navigationTitle("Media found")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .accessibilityIdentifier("metadata.close")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("metadata.sheet")
    }

    private var artwork: some View {
        AsyncImage(url: bestThumbnail) { phase in
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(theme.raisedCard)
                    .aspectRatio(16 / 9, contentMode: .fit)
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                default:
                    ProgressView()
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(alignment: .bottomTrailing) {
            if let duration = metadata.durationSeconds {
                Text(duration.conciseDuration)
                    .font(.caption.monospacedDigit().bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.78), in: Capsule())
                    .padding(10)
            }
        }
        .accessibilityLabel("Thumbnail for \(metadata.title)")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(metadata.title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            if let channel = metadata.channel ?? metadata.uploader {
                Label(channel, systemImage: "person.crop.circle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                IllucetPill(
                    text: "\(metadata.formats.count) formats",
                    systemImage: "square.stack.3d.up"
                )
                if metadata.isLive {
                    IllucetPill(
                        text: metadata.liveStatus ?? "Live",
                        color: IllucetTheme.danger,
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                } else {
                    IllucetPill(
                        text: "On demand",
                        color: IllucetTheme.success,
                        systemImage: "checkmark"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var facts: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
            ],
            spacing: 12
        ) {
            fact(
                "Duration",
                metadata.durationSeconds?.conciseDuration ?? "Unknown",
                "clock"
            )
            fact(
                "Uploaded",
                metadata.uploadDate ?? "Not provided",
                "calendar"
            )
            fact(
                "Top quality",
                topResolution,
                "rectangle.expand.vertical"
            )
            fact(
                "Subtitles",
                metadata.subtitles.isEmpty
                    ? "None listed"
                    : "\(metadata.subtitles.count) tracks",
                "captions.bubble"
            )
        }
    }

    private func fact(
        _ label: String,
        _ value: String,
        _ icon: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(theme.foregroundAccent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            theme.card,
            in: RoundedRectangle(cornerRadius: 14)
        )
        .accessibilityElement(children: .combine)
    }

    private var qualitySummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            IllucetSectionHeader(
                title: "Available source quality",
                subtitle: "Only formats reported by the extractor are shown",
                systemImage: "chart.bar"
            )
            HStack {
                ForEach(
                    Array(FormatSelection.availableResolutions(
                        in: metadata
                    ).prefix(5)),
                    id: \.self
                ) { height in
                    IllucetPill(text: "\(height)p")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
            Text(protocolSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .illucetCard()
    }

    private var chapterSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            IllucetSectionHeader(
                title: "Chapters",
                subtitle: "\(metadata.chapters.count) markers available",
                systemImage: "list.number"
            )
            ForEach(
                Array(metadata.chapters.prefix(3).enumerated()),
                id: \.offset
            ) { _, chapter in
                HStack {
                    Text(
                        chapter.title?.isEmpty == false
                            ? chapter.title!
                            : "Untitled chapter"
                    )
                    .lineLimit(1)
                    Spacer()
                    Text(chapter.startTimeSeconds.conciseDuration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .illucetCard()
    }

    private func descriptionBlock(_ description: String) -> some View {
        DisclosureGroup("Description") {
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 8)
        }
        .illucetCard()
    }

    private var bestThumbnail: URL? {
        metadata.thumbnails.max {
            ($0.width ?? 0) * ($0.height ?? 0)
                < ($1.width ?? 0) * ($1.height ?? 0)
        }?.url
    }

    private var topResolution: String {
        guard let height = FormatSelection.availableResolutions(
            in: metadata
        ).first else { return "Audio only" }
        return height >= 2_160 ? "\(height / 1_080)K" : "\(height)p"
    }

    private var protocolSummary: String {
        let types = Set(metadata.formats.map(\.sourceType)).sorted()
        return "Delivery: \(types.joined(separator: ", ").replacingOccurrences(of: "_", with: " "))"
    }
}
