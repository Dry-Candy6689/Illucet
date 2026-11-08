import AVKit
import Combine
import SwiftUI
import UIKit

@MainActor
protocol HistoryPlaybackAudioSessionControlling: AnyObject {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(
        _ active: Bool,
        options: AVAudioSession.SetActiveOptions
    ) throws
}

@MainActor
final class SystemHistoryPlaybackAudioSession:
    HistoryPlaybackAudioSessionControlling
{
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        try session.setCategory(category, mode: mode, options: options)
    }

    func setActive(
        _ active: Bool,
        options: AVAudioSession.SetActiveOptions
    ) throws {
        try session.setActive(active, options: options)
    }
}

enum HistoryPlaybackAudioSessionError: LocalizedError, Equatable {
    case configuration(String)
    case activation(String)
    case deactivation(String)

    var errorDescription: String? {
        switch self {
        case let .configuration(reason):
            "Playback audio-session configuration failed: \(reason)"
        case let .activation(reason):
            "Playback audio-session activation failed: \(reason)"
        case let .deactivation(reason):
            "Playback audio-session release failed: \(reason)"
        }
    }
}

@MainActor
final class HistoryPlaybackAudioSessionOwner {
    private let session: any HistoryPlaybackAudioSessionControlling
    private(set) var playbackRequested = false
    private(set) var isActive = false

    init(session: any HistoryPlaybackAudioSessionControlling) {
        self.session = session
    }

    func playbackDidStart() throws {
        guard !playbackRequested else { return }
        playbackRequested = true
        do {
            try session.setCategory(
                .playback,
                mode: .moviePlayback,
                options: []
            )
        } catch {
            throw HistoryPlaybackAudioSessionError.configuration(
                error.localizedDescription
            )
        }
        do {
            try session.setActive(true, options: [])
            isActive = true
        } catch {
            throw HistoryPlaybackAudioSessionError.activation(
                error.localizedDescription
            )
        }
    }

    func playbackDidStop() throws {
        playbackRequested = false
        guard isActive else { return }
        do {
            try session.setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
            isActive = false
        } catch {
            throw HistoryPlaybackAudioSessionError.deactivation(
                error.localizedDescription
            )
        }
    }
}

@MainActor
private final class PlayerHolder: ObservableObject {
    let player: AVPlayer
    @Published private(set) var audioSessionIssue: String?
    private let audioSessionOwner: HistoryPlaybackAudioSessionOwner
    private let fileAccess: SavedOutputAccessSession?
    private var playbackNeedsAudioSession = false

    init(
        URL: URL,
        fileAccess: SavedOutputAccessSession? = nil,
        audioSession: any HistoryPlaybackAudioSessionControlling =
            SystemHistoryPlaybackAudioSession()
    ) {
        player = AVPlayer(url: URL)
        self.fileAccess = fileAccess
        audioSessionOwner = HistoryPlaybackAudioSessionOwner(
            session: audioSession
        )
    }

    func synchronizeAudioSession() {
        let needsAudioSession = player.rate != 0
            || player.timeControlStatus != .paused
        guard needsAudioSession != playbackNeedsAudioSession else { return }
        playbackNeedsAudioSession = needsAudioSession
        if needsAudioSession {
            do {
                try audioSessionOwner.playbackDidStart()
                audioSessionIssue = nil
            } catch {
                audioSessionIssue = error.localizedDescription
            }
        } else {
            releaseAudioSession()
        }
    }

    func stopPlayback() {
        player.pause()
        playbackNeedsAudioSession = false
        releaseAudioSession()
    }

    private func releaseAudioSession() {
        do {
            try audioSessionOwner.playbackDidStop()
        } catch {
            audioSessionIssue = error.localizedDescription
        }
    }

    deinit {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

struct OutputPlayer: View {
    @StateObject private var holder: PlayerHolder

    init(URL: URL, fileAccess: SavedOutputAccessSession? = nil) {
        _holder = StateObject(wrappedValue: PlayerHolder(URL: URL, fileAccess: fileAccess))
    }

    var body: some View {
        VStack(spacing: 8) {
            VideoPlayer(player: holder.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityLabel("Output media player")
            if let issue = holder.audioSessionIssue {
                Label(
                    "Audio may follow Ring/Silent: \(issue)",
                    systemImage: "speaker.slash"
                )
                .font(.caption)
                .foregroundStyle(IllucetTheme.warning)
                .accessibilityIdentifier("history.audioSessionIssue")
            }
        }
        .onReceive(
            holder.player.publisher(for: \.timeControlStatus)
        ) { _ in
            holder.synchronizeAudioSession()
        }
        .onReceive(holder.player.publisher(for: \.rate)) { _ in
            holder.synchronizeAudioSession()
        }
        .onDisappear { holder.stopPlayback() }
    }
}

