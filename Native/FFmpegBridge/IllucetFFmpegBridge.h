#ifndef ILLUCET_FFMPEG_BRIDGE_H
#define ILLUCET_FFMPEG_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * All functions in this interface are synchronous. Call them away from the
 * main thread. The bridge never starts a process and never exposes FFmpeg
 * pointers to Swift.
 */
typedef enum IllucetFFmpegStatus {
    ILLUCET_FFMPEG_OK = 0,
    ILLUCET_FFMPEG_INVALID_ARGUMENT = 1,
    ILLUCET_FFMPEG_CANCELLED = 2,
    ILLUCET_FFMPEG_INPUT_ERROR = 3,
    ILLUCET_FFMPEG_OUTPUT_EXISTS = 4,
    ILLUCET_FFMPEG_CODEC_UNAVAILABLE = 5,
    ILLUCET_FFMPEG_PROCESSING_ERROR = 6,
    ILLUCET_FFMPEG_PROBE_ERROR = 7,
    ILLUCET_FFMPEG_IO_ERROR = 8,
    ILLUCET_FFMPEG_OUT_OF_MEMORY = 9
} IllucetFFmpegStatus;

/**
 * Selects the amount of native media verification performed by a probe.
 * Fast structural probing is bounded and does not decode media payloads.
 * Bounded strong probing adds representative start/middle/end decode windows
 * for every non-attached audio/video stream. Full-decode probing reads and
 * hashes every packet and decodes every non-attached audio/video stream.
 */
typedef enum IllucetFFmpegProbeClass {
    ILLUCET_FFMPEG_PROBE_FAST_STRUCTURAL = 1,
    ILLUCET_FFMPEG_PROBE_STRONG_FULL_DECODE = 2,
    ILLUCET_FFMPEG_PROBE_BOUNDED_STRONG = 3
} IllucetFFmpegProbeClass;

/**
 * Progress is in [0, 1] when the total is known and negative when
 * indeterminate. During aggregate-proof verification, stage is NULL and
 * progress is -1 for a cancellation-only poll; clients must not record that
 * poll as progress. Return nonzero to cancel cooperatively.
 */
typedef int (*IllucetFFmpegProgressCallback)(
    const char *stage,
    double progress,
    void *context
);

typedef struct IllucetFFmpegJob IllucetFFmpegJob;

typedef enum IllucetMediaContainer {
    ILLUCET_MEDIA_CONTAINER_MP4 = 1,
    ILLUCET_MEDIA_CONTAINER_MOV = 2,
    ILLUCET_MEDIA_CONTAINER_MATROSKA = 3,
    ILLUCET_MEDIA_CONTAINER_WEBM = 4,
    ILLUCET_MEDIA_CONTAINER_M4A = 5,
    ILLUCET_MEDIA_CONTAINER_MP3 = 6,
    ILLUCET_MEDIA_CONTAINER_OGG = 7,
    ILLUCET_MEDIA_CONTAINER_FLAC = 8,
    ILLUCET_MEDIA_CONTAINER_WAV = 9
} IllucetMediaContainer;

typedef struct IllucetMediaMetadata {
    bool preserve_source_metadata;
    const char *title;
    const char *artist;
    const char *date;
    const char *description;
    const char *comment;
    const char *source_url;
    const char *video_id;
    const char *channel;
} IllucetMediaMetadata;

typedef enum IllucetStreamCopyMode {
    ILLUCET_STREAM_COPY_MERGE = 1,
    ILLUCET_STREAM_COPY_REMUX = 2,
    ILLUCET_STREAM_COPY_EXTRACT_AUDIO = 3,
    ILLUCET_STREAM_COPY_VIDEO_ONLY = 4
} IllucetStreamCopyMode;

typedef struct IllucetStreamCopyRequest {
    IllucetStreamCopyMode mode;
    IllucetMediaContainer container;
    bool fast_start;
    IllucetMediaMetadata metadata;
} IllucetStreamCopyRequest;

typedef enum IllucetAudioCodec {
    ILLUCET_AUDIO_CODEC_AAC = 1,
    ILLUCET_AUDIO_CODEC_MP3 = 2,
    ILLUCET_AUDIO_CODEC_FLAC = 3,
    ILLUCET_AUDIO_CODEC_ALAC = 4,
    ILLUCET_AUDIO_CODEC_OPUS = 5,
    ILLUCET_AUDIO_CODEC_VORBIS = 6,
    ILLUCET_AUDIO_CODEC_PCM_S16LE = 7
} IllucetAudioCodec;

typedef enum IllucetAudioRateControl {
    ILLUCET_AUDIO_RATE_CONTROL_BITRATE = 1,
    ILLUCET_AUDIO_RATE_CONTROL_QUALITY = 2,
    ILLUCET_AUDIO_RATE_CONTROL_LOSSLESS = 3
} IllucetAudioRateControl;

typedef struct IllucetAudioTranscodeRequest {
    IllucetAudioCodec codec;
    IllucetMediaContainer container;
    IllucetAudioRateControl rate_control;
    int bitrate_bits_per_second;
    int quality;
    int sample_rate;
    int channels;
    bool normalize_loudness;
    double integrated_loudness_lufs;
    double loudness_range_lu;
    double true_peak_dbtp;
    bool fast_start;
    IllucetMediaMetadata metadata;
} IllucetAudioTranscodeRequest;

typedef enum IllucetVideoCodec {
    ILLUCET_VIDEO_CODEC_H264 = 1,
    ILLUCET_VIDEO_CODEC_HEVC = 2
} IllucetVideoCodec;

typedef enum IllucetDynamicRange {
    ILLUCET_DYNAMIC_RANGE_PRESERVE = 1,
    ILLUCET_DYNAMIC_RANGE_TO_SDR = 2
} IllucetDynamicRange;

typedef enum IllucetHardwareAcceleration {
    ILLUCET_HARDWARE_ACCELERATION_AUTOMATIC = 1,
    ILLUCET_HARDWARE_ACCELERATION_PREFER_VIDEOTOOLBOX = 2,
    ILLUCET_HARDWARE_ACCELERATION_SOFTWARE_ONLY = 3
} IllucetHardwareAcceleration;

typedef struct IllucetVideoTranscodeRequest {
    IllucetVideoCodec codec;
    IllucetMediaContainer container;
    int bitrate_bits_per_second;
    int width;
    int height;
    int frame_rate_numerator;
    int frame_rate_denominator;
    IllucetDynamicRange dynamic_range;
    IllucetHardwareAcceleration acceleration;
    bool copy_audio;
    bool fast_start;
    IllucetMediaMetadata metadata;
} IllucetVideoTranscodeRequest;

typedef struct IllucetVideoTranscodeReport {
    bool used_videotoolbox;
    bool used_software_fallback;
    char encoder_name[64];
} IllucetVideoTranscodeReport;

typedef enum IllucetSubtitleCodec {
    ILLUCET_SUBTITLE_CODEC_MOV_TEXT = 1,
    ILLUCET_SUBTITLE_CODEC_SUBRIP = 2,
    ILLUCET_SUBTITLE_CODEC_WEBVTT = 3
} IllucetSubtitleCodec;

typedef struct IllucetSubtitleMuxRequest {
    IllucetMediaContainer container;
    IllucetSubtitleCodec codec;
    bool fast_start;
    IllucetMediaMetadata metadata;
    const char *language;
    const char *title;
    bool automatic;
    bool is_default;
    bool is_forced;
} IllucetSubtitleMuxRequest;

typedef struct IllucetChapter {
    const char *title;
    double start_seconds;
    double end_seconds;
} IllucetChapter;

typedef struct IllucetChapterMuxRequest {
    IllucetMediaContainer container;
    bool fast_start;
    IllucetMediaMetadata metadata;
    const IllucetChapter *chapters;
    size_t chapter_count;
    bool preserve_source_chapters;
} IllucetChapterMuxRequest;

IllucetFFmpegJob *illucet_ffmpeg_job_create(
    IllucetFFmpegProgressCallback progress_callback,
    void *progress_context
);
void illucet_ffmpeg_job_cancel(IllucetFFmpegJob *job);
bool illucet_ffmpeg_job_is_cancelled(const IllucetFFmpegJob *job);
void illucet_ffmpeg_job_destroy(IllucetFFmpegJob *job);

const char *illucet_ffmpeg_version(void);
const char *illucet_ffmpeg_configuration(void);

/**
 * Every returned string, including errors, is allocated with av_malloc().
 * Release it with illucet_ffmpeg_string_free().
 */
void illucet_ffmpeg_string_free(char *string);

IllucetFFmpegStatus illucet_ffmpeg_version_json(
    char **result_json,
    char **error
);

/**
 * Generates deterministic, two-second controlled inputs. Existing files are
 * never overwritten. Each output is first written to a unique sibling partial
 * and atomically renamed only after its trailer is written.
 */
IllucetFFmpegStatus illucet_ffmpeg_generate_fixtures(
    const char *video_only_mp4,
    const char *audio_only_m4a,
    const char *incompatible_mkv,
    const char *artwork_jpeg,
    IllucetFFmpegJob *job,
    char **error
);

/**
 * Generates a deterministic two-second audio/video fixture whose audio stream
 * ends after one second. It exists to characterize per-stream tail checks.
 */
IllucetFFmpegStatus illucet_ffmpeg_generate_early_audio_fixture(
    const char *output,
    IllucetFFmpegJob *job,
    char **error
);

IllucetFFmpegStatus illucet_ffmpeg_generate_hdr_fixture(
    const char *output,
    IllucetFFmpegJob *job,
    char **error
);

/** Generates a deterministic fragmented MP4 video-only fixture. */
IllucetFFmpegStatus illucet_ffmpeg_generate_dash_fixture(
    const char *output,
    IllucetFFmpegJob *job,
    char **error
);

/**
 * Remuxes every input stream while replacing or preserving a bounded chapter
 * table. The output is published only after its trailer is written.
 */
IllucetFFmpegStatus illucet_ffmpeg_write_chapters(
    const char *media_input,
    const char *output,
    const IllucetChapterMuxRequest *request,
    IllucetFFmpegJob *job,
    char **error
);

/**
 * Copies selected streams with an explicit container, metadata, and fast-start
 * policy. Invalid stream/container combinations fail before publication.
 */
IllucetFFmpegStatus illucet_ffmpeg_stream_copy(
    const char *first_input,
    const char *second_input,
    const char *output,
    const IllucetStreamCopyRequest *request,
    IllucetFFmpegJob *job,
    char **error
);

IllucetFFmpegStatus illucet_ffmpeg_merge_stream_copy(
    const char *video_input,
    const char *audio_input,
    const char *output,
    IllucetFFmpegJob *job,
    char **error
);

/**
 * Copies the best video and best audio stream from one combined input into
 * the container selected by the output file extension.
 */
IllucetFFmpegStatus illucet_ffmpeg_remux_stream_copy(
    const char *input,
    const char *output,
    IllucetFFmpegJob *job,
    char **error
);

IllucetFFmpegStatus illucet_ffmpeg_extract_audio_copy(
    const char *input,
    const char *output,
    IllucetFFmpegJob *job,
    char **error
);

IllucetFFmpegStatus illucet_ffmpeg_copy_video_only(
    const char *input,
    const char *output,
    IllucetFFmpegJob *job,
    char **error
);

IllucetFFmpegStatus illucet_ffmpeg_transcode_audio_mp3(
    const char *input,
    const char *output,
    int bitrate_bits_per_second,
    IllucetFFmpegJob *job,
    char **error
);

/**
 * Encodes one best audio stream according to a typed request. Unsupported
 * codec/container/rate-control combinations fail before output creation.
 */
IllucetFFmpegStatus illucet_ffmpeg_transcode_audio(
    const char *input,
    const char *output,
    const IllucetAudioTranscodeRequest *request,
    IllucetFFmpegJob *job,
    char **error
);

/**
 * Transcodes video to H.264 through VideoToolbox. The operation fails closed
 * when H.264 cannot be opened; it never substitutes another video codec.
 * A compatible AAC input audio stream is copied without re-encoding.
 */
IllucetFFmpegStatus illucet_ffmpeg_transcode_compatible_mp4(
    const char *input,
    const char *output,
    IllucetFFmpegJob *job,
    char **error
);

/**
 * Encodes H.264 or HEVC through the explicitly requested native policy.
 * The report names the encoder actually used; codec substitution is forbidden.
 */
IllucetFFmpegStatus illucet_ffmpeg_transcode_video(
    const char *input,
    const char *output,
    const IllucetVideoTranscodeRequest *request,
    IllucetVideoTranscodeReport *report,
    IllucetFFmpegJob *job,
    char **error
);

IllucetFFmpegStatus illucet_ffmpeg_attach_mp3_artwork(
    const char *mp3_input,
    const char *jpeg_input,
    const char *output,
    IllucetFFmpegJob *job,
    char **error
);

IllucetFFmpegStatus illucet_ffmpeg_attach_artwork(
    const char *media_input,
    const char *image_input,
    const char *output,
    IllucetMediaContainer container,
    bool fast_start,
    const IllucetMediaMetadata *metadata,
    IllucetFFmpegJob *job,
    char **error
);

/**
 * Copies every existing media stream and adds one decoded/re-encoded text
 * subtitle stream. The typed request must select a codec supported by the
 * requested container. Input paths and transport URLs are never persisted.
 */
IllucetFFmpegStatus illucet_ffmpeg_embed_subtitle(
    const char *media_input,
    const char *subtitle_input,
    const char *output,
    const IllucetSubtitleMuxRequest *request,
    IllucetFFmpegJob *job,
    char **error
);

/**
 * Opens, probes, and completely decodes every non-attached audio/video stream.
 * Failure to decode those streams is a probe failure, not a warning.
 */
IllucetFFmpegStatus illucet_ffmpeg_probe_json(
    const char *input,
    IllucetFFmpegJob *job,
    char **result_json,
    char **error
);

/**
 * Probes one local media file with an explicit verification class. Fast
 * structural probing performs bounded format and packet inspection without
 * allocating decoders or packet hashes. Strong probing preserves the complete
 * decode-and-hash behavior of illucet_ffmpeg_probe_json.
 */
IllucetFFmpegStatus illucet_ffmpeg_probe_json_with_class(
    const char *input,
    IllucetFFmpegProbeClass probe_class,
    IllucetFFmpegJob *job,
    char **result_json,
    char **error
);

/**
 * Convenience entry point used by the simulator/device Stage 0 harness.
 * It creates a unique directory below output_directory, runs every controlled
 * operation above, probes every result, and returns evidence JSON. Returning
 * nonzero from progress_callback cancels the active operation.
 */
IllucetFFmpegStatus illucet_ffmpeg_run_stage0_proof(
    const char *output_directory,
    IllucetFFmpegProgressCallback progress_callback,
    void *progress_context,
    char **result_json,
    char **error
);

#ifdef __cplusplus
}
#endif

#endif
