#if DEBUG
import Foundation

/// Deterministic local media for simulator validation. Unsafe native handles stay
/// inside the native wrapper, as they do in the production processor.
enum NativeMediaFixtures {
    static func generate(in root: URL) throws -> (video: URL, audio: URL) {
        let video = root.appendingPathComponent("fixture-video.mp4")
        let audio = root.appendingPathComponent("fixture-audio.m4a")
        let incompatible = root.appendingPathComponent("fixture-incompatible.mkv")
        let artwork = root.appendingPathComponent("fixture-artwork.jpg")
        var error: UnsafeMutablePointer<CChar>?
        defer { illucet_ffmpeg_string_free(error) }
        let status = video.path.withCString { videoPath in
            audio.path.withCString { audioPath in
                incompatible.path.withCString { incompatiblePath in
                    artwork.path.withCString { artworkPath in
                        illucet_ffmpeg_generate_fixtures(videoPath, audioPath, incompatiblePath, artworkPath, nil, &error)
                    }
                }
            }
        }
        guard status == ILLUCET_FFMPEG_OK else { throw MediaProcessorError.nativeFailure("Fixture generation failed.") }
        return (video, audio)
    }
}
#endif
