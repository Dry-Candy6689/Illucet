#include "IllucetFFmpegBridgeInternal.h"

#define ILLUCET_FAST_FORMAT_PROBE_SIZE (5LL * 1024 * 1024)
#define ILLUCET_FAST_ANALYZE_DURATION (5LL * AV_TIME_BASE)
#define ILLUCET_FAST_FORMAT_PROBE_PACKETS 256
#define ILLUCET_FAST_HEAD_PACKET_LIMIT 64
#define ILLUCET_FAST_TAIL_PACKET_LIMIT 256
#define ILLUCET_FAST_INSPECTED_BYTE_LIMIT (64LL * 1024 * 1024)
#define ILLUCET_FAST_MAX_STREAMS 128
#define ILLUCET_BOUNDED_SAMPLE_WINDOW_COUNT 3
#define ILLUCET_BOUNDED_SAMPLE_PACKET_LIMIT 512
#define ILLUCET_BOUNDED_SAMPLE_BYTE_LIMIT (8LL * 1024 * 1024)
#define ILLUCET_BOUNDED_AUDIO_TARGET_TOLERANCE_US 50000

typedef struct IllucetProbeInspection {
    int64_t packets_inspected;
    int64_t inspected_packet_bytes;
    bool tail_seek_attempted;
    bool tail_seek_succeeded;
    bool tail_seek_reached_eof;
    int64_t tail_stream_packets[ILLUCET_FAST_MAX_STREAMS];
    double latest_primary_packet_end[ILLUCET_FAST_MAX_STREAMS];
    bool has_primary_packet_end[ILLUCET_FAST_MAX_STREAMS];
    int decoded_sample_windows[ILLUCET_FAST_MAX_STREAMS];
} IllucetProbeInspection;

static void illucet_json_dictionary(
    AVBPrint *print,
    const AVDictionary *dictionary,
    bool canonicalize_itunes_description
) {
    const AVDictionaryEntry *canonical_description =
        canonicalize_itunes_description
            ? av_dict_get(dictionary, "description", NULL, 0)
            : NULL;
    av_bprint_chars(print, '{', 1);
    const AVDictionaryEntry *entry = NULL;
    bool first = true;
    while ((entry = av_dict_iterate(dictionary, entry)) != NULL) {
        if (!first) {
            av_bprint_chars(print, ',', 1);
        }
        first = false;
        const char *key = entry->key;
        /*
         * AVFoundation writes its standard iTunes description as the
         * fourCC ©des. FFmpeg's MOV demuxer exports that otherwise-unmapped
         * physical atom as [169]des when export_all is enabled. Canonicalize
         * only that exact atom, without accepting a comment fallback or
         * weakening value verification.
         */
        if (
            canonicalize_itunes_description
            && canonical_description == NULL
            && strcmp(entry->key, "[169]des") == 0
        ) {
            key = "description";
        }
        illucet_json_string(print, key);
        av_bprint_chars(print, ':', 1);
        illucet_json_string(print, entry->value);
    }
    av_bprint_chars(print, '}', 1);
}

static const char *illucet_stream_type(const AVStream *stream) {
    if ((stream->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0) {
        return "video";
    }
    const char *name = av_get_media_type_string(stream->codecpar->codec_type);
    return name != NULL ? name : "unknown";
}

static bool illucet_video_parameters_are_hdr(
    const AVCodecParameters *parameters
) {
    if (parameters == NULL || parameters->codec_type != AVMEDIA_TYPE_VIDEO) {
        return false;
    }
    if (
        parameters->color_trc == AVCOL_TRC_SMPTE2084
        || parameters->color_trc == AVCOL_TRC_ARIB_STD_B67
    ) {
        return true;
    }
    const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(
        (enum AVPixelFormat)parameters->format
    );
    return parameters->color_primaries == AVCOL_PRI_BT2020
        && descriptor != NULL
        && descriptor->nb_components > 0
        && descriptor->comp[0].depth > 8;
}

static int illucet_decode_drain(
    AVCodecContext *decoder,
    AVFrame *frame,
    int64_t *frame_count
) {
    while (true) {
        int result = avcodec_receive_frame(decoder, frame);
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
            return 0;
        }
        if (result < 0) {
            return result;
        }
        (*frame_count)++;
        av_frame_unref(frame);
    }
}

static IllucetFFmpegStatus illucet_validate_structural_streams(
    const AVFormatContext *format,
    char **error
) {
    if (
        format == NULL
        || format->iformat == NULL
        || format->iformat->name == NULL
        || format->iformat->name[0] == '\0'
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_PROBE_ERROR,
            error,
            "Structural probe found no container format"
        );
    }
    if (format->nb_streams == 0 || format->nb_streams > ILLUCET_FAST_MAX_STREAMS) {
        return illucet_error(
            ILLUCET_FFMPEG_PROBE_ERROR,
            error,
            "Structural probe found an invalid stream count"
        );
    }
    double duration = illucet_duration_seconds(format);
    if (!isfinite(duration) || duration <= 0.0) {
        return illucet_error(
            ILLUCET_FFMPEG_PROBE_ERROR,
            error,
            "Structural probe found no sane media duration"
        );
    }
    int primary_streams = 0;
    for (unsigned int index = 0; index < format->nb_streams; index++) {
        const AVStream *stream = format->streams[index];
        const AVCodecParameters *parameters = stream != NULL
            ? stream->codecpar
            : NULL;
        if (stream == NULL || parameters == NULL) {
            return illucet_error(
                ILLUCET_FFMPEG_PROBE_ERROR,
                error,
                "Structural probe found missing stream parameters"
            );
        }
        bool attached =
            (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0;
        bool video = parameters->codec_type == AVMEDIA_TYPE_VIDEO;
        bool audio = parameters->codec_type == AVMEDIA_TYPE_AUDIO;
        bool subtitle = parameters->codec_type == AVMEDIA_TYPE_SUBTITLE;
        if ((video || audio || subtitle) && parameters->codec_id == AV_CODEC_ID_NONE) {
            return illucet_error(
                ILLUCET_FFMPEG_PROBE_ERROR,
                error,
                "Structural probe found a stream without a codec"
            );
        }
        if ((video || audio) && !attached) {
            primary_streams++;
            if (stream->time_base.num <= 0 || stream->time_base.den <= 0) {
                return illucet_error(
                    ILLUCET_FFMPEG_PROBE_ERROR,
                    error,
                    "Structural probe found an invalid media time base"
                );
            }
        }
        if (video && !attached && (parameters->width <= 0 || parameters->height <= 0)) {
            return illucet_error(
                ILLUCET_FFMPEG_PROBE_ERROR,
                error,
                "Structural probe found invalid video dimensions"
            );
        }
        if (
            audio
            && (
                parameters->sample_rate <= 0
                || parameters->ch_layout.nb_channels <= 0
            )
        ) {
            return illucet_error(
                ILLUCET_FFMPEG_PROBE_ERROR,
                error,
                "Structural probe found invalid audio parameters"
            );
        }
    }
    if (primary_streams == 0) {
        return illucet_error(
            ILLUCET_FFMPEG_PROBE_ERROR,
            error,
            "Structural probe found no audio or video stream"
        );
    }
    return ILLUCET_FFMPEG_OK;
}

static bool illucet_primary_stream(const AVStream *stream) {
    if (stream == NULL || stream->codecpar == NULL) {
        return false;
    }
    bool attached =
        (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0;
    return !attached
        && (
            stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO
            || stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO
        );
}

static IllucetFFmpegStatus illucet_inspect_structural_packets(
    AVFormatContext *format,
    IllucetFFmpegJob *job,
    AVPacket *packet,
    int packet_limit,
    double progress,
    int64_t *stream_packets,
    IllucetProbeInspection *inspection,
    bool tail_sample,
    bool *reached_eof,
    bool *byte_limit_reached,
    char **error
) {
    *reached_eof = false;
    *byte_limit_reached = false;
    for (int sample = 0; sample < packet_limit; sample++) {
        int result = av_read_frame(format, packet);
        if (result == AVERROR_EOF) {
            *reached_eof = true;
            return ILLUCET_FFMPEG_OK;
        }
        if (result < 0) {
            if (illucet_job_cancelled(job)) {
                return illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
            }
            return illucet_av_error(
                ILLUCET_FFMPEG_PROBE_ERROR,
                error,
                result,
                "Cannot structurally inspect media packets"
            );
        }
        if (
            packet->stream_index < 0
            || (unsigned int)packet->stream_index >= format->nb_streams
        ) {
            av_packet_unref(packet);
            return illucet_error(
                ILLUCET_FFMPEG_PROBE_ERROR,
                error,
                "Structural probe found an invalid packet stream index"
            );
        }
        AVStream *stream = format->streams[packet->stream_index];
        bool primary = illucet_primary_stream(stream);
        if (
            (packet->flags & AV_PKT_FLAG_CORRUPT) != 0
            || packet->size < 0
            || (packet->size > 0 && packet->data == NULL)
            || (primary && packet->size == 0)
        ) {
            av_packet_unref(packet);
            return illucet_error(
                ILLUCET_FFMPEG_PROBE_ERROR,
                error,
                "Structural probe found a corrupt media packet"
            );
        }
        int64_t packet_bytes = packet->size > 0 ? packet->size : 0;
        if (
            packet_bytes
                > ILLUCET_FAST_INSPECTED_BYTE_LIMIT
                    - inspection->inspected_packet_bytes
        ) {
            av_packet_unref(packet);
            *byte_limit_reached = true;
            return ILLUCET_FFMPEG_OK;
        }
        inspection->packets_inspected++;
        inspection->inspected_packet_bytes += packet_bytes;
        stream_packets[packet->stream_index]++;
        if (tail_sample) {
            inspection->tail_stream_packets[packet->stream_index]++;
        }
        if (primary) {
            int64_t timestamp = packet->pts != AV_NOPTS_VALUE
                ? packet->pts
                : packet->dts;
            if (timestamp != AV_NOPTS_VALUE) {
                int64_t packet_end = timestamp;
                if (
                    packet->duration > 0
                    && timestamp <= INT64_MAX - packet->duration
                ) {
                    packet_end += packet->duration;
                }
                double start = format->start_time != AV_NOPTS_VALUE
                    ? (double)format->start_time / AV_TIME_BASE
                    : 0.0;
                double end = packet_end * av_q2d(stream->time_base) - start;
                if (
                    isfinite(end)
                    && (
                        !inspection->has_primary_packet_end[
                            packet->stream_index
                        ]
                        || end > inspection->latest_primary_packet_end[
                            packet->stream_index
                        ]
                    )
                ) {
                    inspection->latest_primary_packet_end[
                        packet->stream_index
                    ] = end;
                    inspection->has_primary_packet_end[
                        packet->stream_index
                    ] = true;
                }
            }
        }
        av_packet_unref(packet);
        if (illucet_progress(job, "probe", progress)) {
            return illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
        }
    }
    return ILLUCET_FFMPEG_OK;
}

static IllucetFFmpegStatus illucet_run_structural_inspection(
    AVFormatContext *format,
    IllucetFFmpegJob *job,
    AVPacket *packet,
    int64_t *stream_packets,
    IllucetProbeInspection *inspection,
    char **error
) {
    if (
        format->pb == NULL
        || (format->pb->seekable & AVIO_SEEKABLE_NORMAL) == 0
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_PROBE_ERROR,
            error,
            "Structural probe requires a seekable local media file"
        );
    }
    int64_t start = format->start_time != AV_NOPTS_VALUE
        ? format->start_time
        : 0;
    int seek_result = avformat_seek_file(
        format,
        -1,
        INT64_MIN,
        start,
        start,
        AVSEEK_FLAG_BACKWARD
    );
    if (seek_result < 0) {
        seek_result = av_seek_frame(format, -1, start, AVSEEK_FLAG_BACKWARD);
    }
    if (seek_result < 0) {
        return illucet_av_error(
            ILLUCET_FFMPEG_PROBE_ERROR,
            error,
            seek_result,
            "Cannot seek to the media head for structural inspection"
        );
    }
    avformat_flush(format);

    bool head_eof = false;
    bool byte_limit_reached = false;
    IllucetFFmpegStatus status = illucet_inspect_structural_packets(
        format,
        job,
        packet,
        ILLUCET_FAST_HEAD_PACKET_LIMIT,
        0.25,
        stream_packets,
        inspection,
        false,
        &head_eof,
        &byte_limit_reached,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    if (byte_limit_reached) {
        return illucet_error(
            ILLUCET_FFMPEG_PROBE_ERROR,
            error,
            "Structural probe exhausted its packet-byte inspection bound"
        );
    }

    inspection->tail_seek_attempted = true;
    int64_t duration = format->duration;
    if (start > INT64_MAX - duration) {
        return illucet_error(
            ILLUCET_FFMPEG_PROBE_ERROR,
            error,
            "Structural probe found an invalid media timeline"
        );
    }
    int64_t tail_window = duration / 50;
    if (tail_window < AV_TIME_BASE / 2) {
        tail_window = AV_TIME_BASE / 2;
    }
    if (tail_window > 2LL * AV_TIME_BASE) {
        tail_window = 2LL * AV_TIME_BASE;
    }
    int64_t target = start + duration - tail_window;
    if (target < start) {
        target = start;
    }
    int64_t end = start + duration;
    // Structural inspection reads packets without decoding them. Seeking only
    // to keyframes can land many seconds before the tail and exhaust the packet
    // budget on healthy long-GOP media. Decode windows below still use keyframes.
    seek_result = avformat_seek_file(
        format,
        -1,
        start,
        target,
        end,
        AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY
    );
    if (seek_result < 0) {
        seek_result = av_seek_frame(
            format,
            -1,
            target,
            AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY
        );
    }
    if (seek_result < 0) {
        return illucet_av_error(
            ILLUCET_FFMPEG_PROBE_ERROR,
            error,
            seek_result,
            "Cannot seek to the media tail for structural inspection"
        );
    }
    inspection->tail_seek_succeeded = true;
    avformat_flush(format);

    int64_t primary_packets_before_tail = 0;
    for (unsigned int index = 0; index < format->nb_streams; index++) {
        if (illucet_primary_stream(format->streams[index])) {
            primary_packets_before_tail += stream_packets[index];
        }
    }
    bool tail_eof = false;
    status = illucet_inspect_structural_packets(
        format,
        job,
        packet,
        ILLUCET_FAST_TAIL_PACKET_LIMIT,
        0.75,
        stream_packets,
        inspection,
        true,
        &tail_eof,
        &byte_limit_reached,
        error
    );
    inspection->tail_seek_reached_eof = tail_eof;
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    if (byte_limit_reached) {
        return illucet_error(
            ILLUCET_FFMPEG_PROBE_ERROR,
            error,
            "Structural probe exhausted its packet-byte inspection bound"
        );
    }
    int64_t primary_packets_after_tail = 0;
    for (unsigned int index = 0; index < format->nb_streams; index++) {
        if (illucet_primary_stream(format->streams[index])) {
            primary_packets_after_tail += stream_packets[index];
        }
    }
    if (primary_packets_after_tail <= primary_packets_before_tail) {
        return illucet_error(
            ILLUCET_FFMPEG_PROBE_ERROR,
            error,
            "Structural probe found no media packets near the declared tail"
        );
    }
    double duration_seconds = illucet_duration_seconds(format);
    double tolerance = duration_seconds * 0.02;
    if (tolerance < 0.5) {
        tolerance = 0.5;
    }
    if (tolerance > 3.0) {
        tolerance = 3.0;
    }
    for (unsigned int index = 0; index < format->nb_streams; index++) {
        if (!illucet_primary_stream(format->streams[index])) {
            continue;
        }
        if (stream_packets[index] <= 0) {
            return illucet_error(
                ILLUCET_FFMPEG_PROBE_ERROR,
                error,
                "Structural probe found a media stream without packets"
            );
        }
        if (
            inspection->tail_stream_packets[index] <= 0
            || !inspection->has_primary_packet_end[index]
            || inspection->latest_primary_packet_end[index]
                < duration_seconds - tolerance
        ) {
            return illucet_error(
                ILLUCET_FFMPEG_PROBE_ERROR,
                error,
                "Structural probe found an obviously truncated media stream"
            );
        }
    }
    return ILLUCET_FFMPEG_OK;
}

static void illucet_record_decoded_sample(
    const AVStream *stream,
    int64_t target,
    const AVFrame *frame,
    int64_t fallback_packet_timestamp,
    bool physical_audio_window,
    int64_t *decoded_frames,
    bool *decoded_in_window
) {
    (*decoded_frames)++;
    if (*decoded_in_window) {
        return;
    }
    int64_t frame_timestamp = frame->best_effort_timestamp;
    if (frame_timestamp == AV_NOPTS_VALUE) {
        frame_timestamp = frame->pts;
    }
    if (frame_timestamp == AV_NOPTS_VALUE) {
        frame_timestamp = frame->pkt_dts;
    }
    bool frame_reaches_target =
        frame_timestamp != AV_NOPTS_VALUE
        && av_compare_ts(
            frame_timestamp,
            stream->time_base,
            target,
            AV_TIME_BASE_Q
        ) >= 0;
    // Some audio decoders preserve codec-delay frame timestamps that are not
    // on the demuxer's seek timeline. MP3 TOC seeks can also land one or two
    // packets before the requested time. A decoded packet within this narrow
    // audio-only tolerance is still a truthful representative sample.
    int64_t audio_target =
        target > INT64_MIN + ILLUCET_BOUNDED_AUDIO_TARGET_TOLERANCE_US
        ? target - ILLUCET_BOUNDED_AUDIO_TARGET_TOLERANCE_US
        : INT64_MIN;
    bool audio_packet_reaches_target =
        stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO
        && fallback_packet_timestamp != AV_NOPTS_VALUE
        && av_compare_ts(
            fallback_packet_timestamp,
            stream->time_base,
            audio_target,
            AV_TIME_BASE_Q
        ) >= 0;
    if (
        frame_reaches_target
        || audio_packet_reaches_target
        || physical_audio_window
    ) {
        *decoded_in_window = true;
    }
}

static int illucet_decode_sample_packet(
    AVCodecContext *decoder,
    const AVStream *stream,
    int64_t target,
    bool physical_audio_window,
    AVPacket *packet,
    AVFrame *frame,
    int64_t *decoded_frames,
    bool *decoded_in_window
) {
    int64_t packet_timestamp = packet->pts;
    if (packet_timestamp == AV_NOPTS_VALUE) {
        packet_timestamp = packet->dts;
    }
    int result = avcodec_send_packet(decoder, packet);
    if (result == AVERROR(EAGAIN)) {
        while (true) {
            result = avcodec_receive_frame(decoder, frame);
            if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
                break;
            }
            if (result < 0) {
                return result;
            }
            illucet_record_decoded_sample(
                stream,
                target,
                frame,
                AV_NOPTS_VALUE,
                physical_audio_window,
                decoded_frames,
                decoded_in_window
            );
            av_frame_unref(frame);
        }
        result = avcodec_send_packet(decoder, packet);
    }
    if (result < 0) {
        return result;
    }
    while (true) {
        result = avcodec_receive_frame(decoder, frame);
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
            return 0;
        }
        if (result < 0) {
            return result;
        }
        illucet_record_decoded_sample(
            stream,
            target,
            frame,
            packet_timestamp,
            physical_audio_window,
            decoded_frames,
            decoded_in_window
        );
        av_frame_unref(frame);
    }
}

static bool illucet_all_primary_streams_sampled(
    const AVFormatContext *format,
    const bool *decoded_in_window
) {
    for (unsigned int index = 0; index < format->nb_streams; index++) {
        if (
            illucet_primary_stream(format->streams[index])
            && !decoded_in_window[index]
        ) {
            return false;
        }
    }
    return true;
}

static bool illucet_is_audio_only(const AVFormatContext *format) {
    unsigned int primary_count = 0;
    for (unsigned int index = 0; index < format->nb_streams; index++) {
        const AVStream *stream = format->streams[index];
        if (!illucet_primary_stream(stream)) {
            continue;
        }
        primary_count++;
        if (stream->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
            return false;
        }
    }
    return primary_count == 1;
}

static IllucetFFmpegStatus illucet_decode_representative_windows(
    AVFormatContext *format,
    IllucetFFmpegJob *job,
    AVCodecContext **decoders,
    AVPacket *packet,
    AVFrame *frame,
    int64_t *decoded_frames,
    IllucetProbeInspection *inspection,
    char **error
) {
    if (
        format == NULL
        || format->duration <= 0
        || format->nb_streams == 0
        || format->nb_streams > ILLUCET_FAST_MAX_STREAMS
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_PROBE_ERROR,
            error,
            "Bounded probe found an invalid media timeline"
        );
    }
    int64_t start = format->start_time != AV_NOPTS_VALUE
        ? format->start_time
        : 0;
    if (start > INT64_MAX - format->duration) {
        return illucet_error(
            ILLUCET_FFMPEG_PROBE_ERROR,
            error,
            "Bounded probe found an invalid media timeline"
        );
    }
    int64_t end = start + format->duration;
    int64_t tail_lead = format->duration / 10;
    if (tail_lead < AV_TIME_BASE / 2) {
        tail_lead = AV_TIME_BASE / 2;
    }
    if (tail_lead > 2LL * AV_TIME_BASE) {
        tail_lead = 2LL * AV_TIME_BASE;
    }
    if (tail_lead >= format->duration) {
        tail_lead = format->duration / 4;
    }
    const int64_t targets[ILLUCET_BOUNDED_SAMPLE_WINDOW_COUNT] = {
        start,
        start + format->duration / 2,
        end - tail_lead,
    };
    bool audio_only = illucet_is_audio_only(format);
    int64_t input_size = format->pb != NULL ? avio_size(format->pb) : -1;
    int64_t previous_audio_seek_position = -1;

    for (
        int window = 0;
        window < ILLUCET_BOUNDED_SAMPLE_WINDOW_COUNT;
        window++
    ) {
        for (unsigned int index = 0; index < format->nb_streams; index++) {
            if (decoders[index] != NULL) {
                avcodec_flush_buffers(decoders[index]);
            }
        }
        int seek_result = avformat_seek_file(
            format,
            -1,
            start,
            targets[window],
            end,
            AVSEEK_FLAG_BACKWARD
        );
        if (seek_result < 0) {
            seek_result = av_seek_frame(
                format,
                -1,
                targets[window],
                AVSEEK_FLAG_BACKWARD
            );
        }
        if (seek_result < 0) {
            return illucet_av_error(
                ILLUCET_FFMPEG_PROBE_ERROR,
                error,
                seek_result,
                "Cannot seek to a representative decode window"
            );
        }
        avformat_flush(format);
        int64_t window_seek_position = format->pb != NULL
            ? avio_tell(format->pb)
            : -1;
        int64_t minimum_seek_advance = input_size > 0
            ? FFMAX(1, input_size / 100)
            : 1;
        // Some audio-only demuxers omit or reset timestamps after a seek.
        // In that case a decoded frame from three distinct, increasing file
        // positions is the bounded equivalent of timestamped sample windows.
        bool physical_audio_window =
            audio_only
            && window_seek_position >= 0
            && window_seek_position < input_size
            && (
                previous_audio_seek_position < 0
                || window_seek_position - previous_audio_seek_position
                    >= minimum_seek_advance
            );
        if (audio_only && window_seek_position >= 0) {
            previous_audio_seek_position = window_seek_position;
        }

        bool decoded_in_window[ILLUCET_FAST_MAX_STREAMS] = {false};
        int64_t decoded_frames_before_window[ILLUCET_FAST_MAX_STREAMS];
        int64_t latest_packet_timestamp[ILLUCET_FAST_MAX_STREAMS];
        for (unsigned int index = 0; index < format->nb_streams; index++) {
            decoded_frames_before_window[index] = decoded_frames[index];
            latest_packet_timestamp[index] = AV_NOPTS_VALUE;
        }
        int64_t window_bytes = 0;
        bool reached_eof = false;
        for (
            int sample = 0;
            sample < ILLUCET_BOUNDED_SAMPLE_PACKET_LIMIT;
            sample++
        ) {
            if (illucet_job_cancelled(job)) {
                return illucet_error(
                    ILLUCET_FFMPEG_CANCELLED,
                    error,
                    "Cancelled"
                );
            }
            int result = av_read_frame(format, packet);
            if (result == AVERROR_EOF) {
                reached_eof = true;
                break;
            }
            if (result < 0) {
                if (illucet_job_cancelled(job)) {
                    return illucet_error(
                        ILLUCET_FFMPEG_CANCELLED,
                        error,
                        "Cancelled"
                    );
                }
                return illucet_av_error(
                    ILLUCET_FFMPEG_PROBE_ERROR,
                    error,
                    result,
                    "Cannot read a representative decode window"
                );
            }
            if (
                packet->stream_index < 0
                || (unsigned int)packet->stream_index >= format->nb_streams
                || (packet->flags & AV_PKT_FLAG_CORRUPT) != 0
                || packet->size < 0
                || (packet->size > 0 && packet->data == NULL)
            ) {
                av_packet_unref(packet);
                return illucet_error(
                    ILLUCET_FFMPEG_PROBE_ERROR,
                    error,
                    "Bounded probe found a corrupt media packet"
                );
            }
            int64_t packet_bytes = packet->size > 0 ? packet->size : 0;
            if (
                packet_bytes
                    > ILLUCET_BOUNDED_SAMPLE_BYTE_LIMIT - window_bytes
            ) {
                av_packet_unref(packet);
                return illucet_error(
                    ILLUCET_FFMPEG_PROBE_ERROR,
                    error,
                    "Bounded probe exhausted a sample-window byte bound"
                );
            }
            window_bytes += packet_bytes;
            inspection->packets_inspected++;
            if (
                packet_bytes
                    > INT64_MAX - inspection->inspected_packet_bytes
            ) {
                inspection->inspected_packet_bytes = INT64_MAX;
            } else {
                inspection->inspected_packet_bytes += packet_bytes;
            }
            size_t stream_index = (size_t)packet->stream_index;
            latest_packet_timestamp[stream_index] = packet->pts;
            if (latest_packet_timestamp[stream_index] == AV_NOPTS_VALUE) {
                latest_packet_timestamp[stream_index] = packet->dts;
            }
            if (decoders[stream_index] != NULL) {
                result = illucet_decode_sample_packet(
                    decoders[stream_index],
                    format->streams[stream_index],
                    targets[window],
                    physical_audio_window,
                    packet,
                    frame,
                    &decoded_frames[stream_index],
                    &decoded_in_window[stream_index]
                );
                if (result < 0) {
                    av_packet_unref(packet);
                    return illucet_av_error(
                        ILLUCET_FFMPEG_PROBE_ERROR,
                        error,
                        result,
                        "A representative media sample failed decode"
                    );
                }
            }
            av_packet_unref(packet);
            if (illucet_all_primary_streams_sampled(format, decoded_in_window)) {
                break;
            }
            double progress = 0.35 + 0.2 * window;
            if (illucet_progress(job, "probe", progress)) {
                return illucet_error(
                    ILLUCET_FFMPEG_CANCELLED,
                    error,
                    "Cancelled"
                );
            }
        }

        if (reached_eof && !illucet_all_primary_streams_sampled(
                format,
                decoded_in_window
            )) {
            for (
                unsigned int index = 0;
                index < format->nb_streams;
                index++
            ) {
                if (decoders[index] == NULL || decoded_in_window[index]) {
                    continue;
                }
                int result = avcodec_send_packet(decoders[index], NULL);
                if (result >= 0) {
                    while (true) {
                        result = avcodec_receive_frame(
                            decoders[index],
                            frame
                        );
                        if (
                            result == AVERROR(EAGAIN)
                            || result == AVERROR_EOF
                        ) {
                            break;
                        }
                        if (result < 0) {
                            return illucet_av_error(
                                ILLUCET_FFMPEG_PROBE_ERROR,
                                error,
                                result,
                                "A representative decoder flush failed"
                            );
                        }
                        illucet_record_decoded_sample(
                            format->streams[index],
                            targets[window],
                            frame,
                            AV_NOPTS_VALUE,
                            physical_audio_window,
                            &decoded_frames[index],
                            &decoded_in_window[index]
                        );
                        av_frame_unref(frame);
                    }
                }
            }
            // A short audio-only file may place multiple time seeks on the
            // same container page and expose no packet/frame timestamps. If
            // the bounded window decoded from that successful seek through
            // EOF, it necessarily covered the requested near-tail sample.
            // Large files still fail at the packet/byte bounds rather than
            // silently turning this bounded mode into a full-file decode.
            for (
                unsigned int index = 0;
                audio_only && index < format->nb_streams;
                index++
            ) {
                if (
                    illucet_primary_stream(format->streams[index])
                    && decoded_frames[index]
                        > decoded_frames_before_window[index]
                ) {
                    decoded_in_window[index] = true;
                }
            }
        }
        if (!illucet_all_primary_streams_sampled(format, decoded_in_window)) {
            for (
                unsigned int index = 0;
                index < format->nb_streams;
                index++
            ) {
                if (
                    !illucet_primary_stream(format->streams[index])
                    || decoded_in_window[index]
                ) {
                    continue;
                }
                double latest_packet_seconds =
                    latest_packet_timestamp[index] == AV_NOPTS_VALUE
                    ? -1.0
                    : latest_packet_timestamp[index]
                        * av_q2d(format->streams[index]->time_base);
                return illucet_error(
                    ILLUCET_FFMPEG_PROBE_ERROR,
                    error,
                    "Primary stream %u did not decode at %.6f seconds; latest packet timestamp %.6f seconds; seek byte %lld of %lld",
                    index,
                    targets[window] / (double)AV_TIME_BASE,
                    latest_packet_seconds,
                    (long long)window_seek_position,
                    (long long)input_size
                );
            }
            return illucet_error(
                ILLUCET_FFMPEG_PROBE_ERROR,
                error,
                "A primary media stream did not decode in every representative window"
            );
        }
        for (unsigned int index = 0; index < format->nb_streams; index++) {
            if (illucet_primary_stream(format->streams[index])) {
                inspection->decoded_sample_windows[index]++;
            }
        }
    }
    return ILLUCET_FFMPEG_OK;
}

IllucetFFmpegStatus illucet_ffmpeg_probe_json_with_class(
    const char *input_path,
    IllucetFFmpegProbeClass probe_class,
    IllucetFFmpegJob *job,
    char **result_json,
    char **error
) {
    illucet_clear_error(error);
    if (result_json == NULL) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "result_json is required"
        );
    }
    *result_json = NULL;
    if (
        probe_class != ILLUCET_FFMPEG_PROBE_FAST_STRUCTURAL
        && probe_class != ILLUCET_FFMPEG_PROBE_BOUNDED_STRONG
        && probe_class != ILLUCET_FFMPEG_PROBE_STRONG_FULL_DECODE
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "A valid FFmpeg probe class is required"
        );
    }
    if (!illucet_path_is_valid(input_path)) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "A valid input path is required"
        );
    }
    bool full_decode =
        probe_class == ILLUCET_FFMPEG_PROBE_STRONG_FULL_DECODE;
    bool bounded_strong =
        probe_class == ILLUCET_FFMPEG_PROBE_BOUNDED_STRONG;
    bool needs_decoders = full_decode || bounded_strong;
    if (illucet_progress(job, "probe", 0.0)) {
        return illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
    }
    struct stat file_status;
    if (
        !full_decode
        && (
            stat(input_path, &file_status) != 0
            || !S_ISREG(file_status.st_mode)
            || file_status.st_size <= 0
        )
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INPUT_ERROR,
            error,
            "Structural probe requires a non-empty regular file"
        );
    }
    IllucetInput input;
    memset(&input, 0, sizeof(input));
    AVCodecContext **decoders = NULL;
    int64_t *decoded_frames = NULL;
    struct AVSHA **packet_hashers = NULL;
    uint8_t (*packet_digests)[32] = NULL;
    int64_t *stream_packets = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL;
    size_t stream_count = 0;
    IllucetProbeInspection inspection;
    memset(&inspection, 0, sizeof(inspection));
    IllucetFFmpegStatus status = illucet_open_input_with_limits(
        input_path,
        job,
        &input,
        full_decode ? 0 : ILLUCET_FAST_FORMAT_PROBE_SIZE,
        full_decode ? 0 : ILLUCET_FAST_ANALYZE_DURATION,
        full_decode ? 0 : ILLUCET_FAST_FORMAT_PROBE_PACKETS,
        true,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    if (input.format == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            "Probe input opened without a format context"
        );
        goto cleanup;
    }
    stream_count = input.format->nb_streams;
    if (!full_decode) {
        status = illucet_validate_structural_streams(input.format, error);
        if (status != ILLUCET_FFMPEG_OK) {
            goto cleanup;
        }
        stream_packets = av_calloc(stream_count, sizeof(*stream_packets));
    }
    if (stream_count > ILLUCET_FAST_MAX_STREAMS) {
        status = illucet_error(
            ILLUCET_FFMPEG_PROBE_ERROR,
            error,
            "Probe found an excessive stream count"
        );
        goto cleanup;
    }
    if (needs_decoders) {
        decoders = av_calloc(stream_count, sizeof(*decoders));
        decoded_frames = av_calloc(stream_count, sizeof(*decoded_frames));
    }
    if (full_decode) {
        packet_hashers = av_calloc(stream_count, sizeof(*packet_hashers));
        packet_digests = av_calloc(stream_count, sizeof(*packet_digests));
    }
    if (
        (!full_decode && stream_count > 0 && stream_packets == NULL)
        || (
            needs_decoders
            && (
                (stream_count > 0 && decoders == NULL)
                || (stream_count > 0 && decoded_frames == NULL)
            )
        )
        || (
            full_decode
            && (
                (stream_count > 0 && packet_hashers == NULL)
                || (stream_count > 0 && packet_digests == NULL)
            )
        )
    ) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate probing state"
        );
        goto cleanup;
    }
    for (size_t index = 0; needs_decoders && index < stream_count; index++) {
        if (full_decode) {
            packet_hashers[index] = av_sha_alloc();
            if (
                packet_hashers[index] == NULL
                || av_sha_init(packet_hashers[index], 256) < 0
            ) {
                status = illucet_error(
                    ILLUCET_FFMPEG_OUT_OF_MEMORY,
                    error,
                    "Cannot allocate packet SHA-256 state"
                );
                goto cleanup;
            }
        }
        AVStream *stream = input.format->streams[index];
        bool attached =
            (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0;
        bool should_decode =
            stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO
            || stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO;
        if (!should_decode || attached) {
            continue;
        }
        const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
        if (codec == NULL) {
            status = illucet_error(
                ILLUCET_FFMPEG_PROBE_ERROR,
                error,
                "Decoder unavailable for non-attached stream %zu",
                index
            );
            goto cleanup;
        }
        decoders[index] = avcodec_alloc_context3(codec);
        if (decoders[index] == NULL) {
            status = illucet_error(
                ILLUCET_FFMPEG_OUT_OF_MEMORY,
                error,
                "Cannot allocate probe decoder"
            );
            goto cleanup;
        }
        int result = avcodec_parameters_to_context(
            decoders[index],
            stream->codecpar
        );
        if (result >= 0) {
            decoders[index]->pkt_timebase = stream->time_base;
            result = avcodec_open2(decoders[index], codec, NULL);
        }
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROBE_ERROR,
                error,
                result,
                "Cannot open probe decoder"
            );
            goto cleanup;
        }
    }
    packet = av_packet_alloc();
    if (needs_decoders) {
        frame = av_frame_alloc();
    }
    if (packet == NULL || (needs_decoders && frame == NULL)) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate probe buffers"
        );
        goto cleanup;
    }
    double duration = illucet_duration_seconds(input.format);
    if (!full_decode) {
        status = illucet_run_structural_inspection(
            input.format,
            job,
            packet,
            stream_packets,
            &inspection,
            error
        );
        if (status != ILLUCET_FFMPEG_OK) {
            goto cleanup;
        }
        if (bounded_strong) {
            status = illucet_decode_representative_windows(
                input.format,
                job,
                decoders,
                packet,
                frame,
                decoded_frames,
                &inspection,
                error
            );
            if (status != ILLUCET_FFMPEG_OK) {
                goto cleanup;
            }
        }
    } else {
        while (true) {
            int result = av_read_frame(input.format, packet);
            if (result == AVERROR_EOF) {
                break;
            }
            if (result < 0) {
                if (illucet_job_cancelled(job)) {
                    status = illucet_error(
                        ILLUCET_FFMPEG_CANCELLED,
                        error,
                        "Cancelled"
                    );
                } else {
                    status = illucet_av_error(
                        ILLUCET_FFMPEG_PROBE_ERROR,
                        error,
                        result,
                        "Cannot fully read probed media"
                    );
                }
                goto cleanup;
            }
            if (
                packet->stream_index < 0
                || (size_t)packet->stream_index >= stream_count
            ) {
                av_packet_unref(packet);
                status = illucet_error(
                    ILLUCET_FFMPEG_PROBE_ERROR,
                    error,
                    "Full probe found an invalid packet stream index"
                );
                goto cleanup;
            }
            size_t stream_index = (size_t)packet->stream_index;
            int64_t timestamp = illucet_packet_timestamp(packet);
            AVRational time_base =
                input.format->streams[stream_index]->time_base;
            inspection.packets_inspected++;
            if (packet->size > 0) {
                if (packet->data == NULL) {
                    av_packet_unref(packet);
                    status = illucet_error(
                        ILLUCET_FFMPEG_PROBE_ERROR,
                        error,
                        "Full probe found an invalid packet payload"
                    );
                    goto cleanup;
                }
                int64_t packet_bytes = packet->size;
                if (
                    packet_bytes
                        > INT64_MAX - inspection.inspected_packet_bytes
                ) {
                    inspection.inspected_packet_bytes = INT64_MAX;
                } else {
                    inspection.inspected_packet_bytes += packet_bytes;
                }
                av_sha_update(
                    packet_hashers[stream_index],
                    packet->data,
                    (size_t)packet->size
                );
            }
            if (decoders[stream_index] != NULL) {
                result = avcodec_send_packet(
                    decoders[stream_index],
                    packet
                );
                av_packet_unref(packet);
                if (result >= 0) {
                    result = illucet_decode_drain(
                        decoders[stream_index],
                        frame,
                        &decoded_frames[stream_index]
                    );
                }
                if (result < 0) {
                    status = illucet_av_error(
                        ILLUCET_FFMPEG_PROBE_ERROR,
                        error,
                        result,
                        "A non-attached stream failed full decode"
                    );
                    goto cleanup;
                }
            } else {
                av_packet_unref(packet);
            }
            double progress = -1.0;
            if (duration > 0.0) {
                progress = timestamp * av_q2d(time_base) / duration;
            }
            if (illucet_progress(job, "probe", progress)) {
                status = illucet_error(
                    ILLUCET_FFMPEG_CANCELLED,
                    error,
                    "Cancelled"
                );
                goto cleanup;
            }
        }
        for (size_t index = 0; index < stream_count; index++) {
            if (decoders[index] == NULL) {
                continue;
            }
            int result = avcodec_send_packet(decoders[index], NULL);
            if (result >= 0) {
                result = illucet_decode_drain(
                    decoders[index],
                    frame,
                    &decoded_frames[index]
                );
            }
            if (result < 0) {
                status = illucet_av_error(
                    ILLUCET_FFMPEG_PROBE_ERROR,
                    error,
                    result,
                    "A non-attached stream failed decoder flush"
                );
                goto cleanup;
            }
            if (decoded_frames[index] <= 0) {
                status = illucet_error(
                    ILLUCET_FFMPEG_PROBE_ERROR,
                    error,
                    "A non-attached audio/video stream decoded zero frames"
                );
                goto cleanup;
            }
        }
        for (size_t index = 0; index < stream_count; index++) {
            av_sha_final(packet_hashers[index], packet_digests[index]);
        }
    }

    double reported_duration = duration;
    if (
        reported_duration < 0.0
        && stream_count == 1
        && input.format->streams[0]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO
    ) {
        reported_duration = 0.0;
    }
    int64_t size = input.format->pb != NULL
        ? avio_size(input.format->pb)
        : -1;
    if (size < 0) {
        struct stat file_status;
        if (stat(input_path, &file_status) == 0) {
            size = file_status.st_size;
        }
    }
    int video_count = 0;
    int audio_count = 0;
    int subtitle_count = 0;
    int artwork_count = 0;
    for (size_t index = 0; index < stream_count; index++) {
        AVStream *stream = input.format->streams[index];
        if ((stream->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0) {
            artwork_count++;
        } else if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            video_count++;
        } else if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            audio_count++;
        } else if (stream->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            subtitle_count++;
        }
    }
    AVBPrint print;
    av_bprint_init(&print, 4096, 2 * 1024 * 1024);
    av_bprintf(&print, "{\"verificationClass\":");
    illucet_json_string(
        &print,
        full_decode
            ? "strongFullDecode"
            : (bounded_strong ? "boundedStrong" : "fastStructural")
    );
    av_bprintf(
        &print,
        ",\"fullDecodePerformed\":%s"
        ",\"packetsInspected\":%" PRId64
        ",\"inspectedPacketBytes\":%" PRId64
        ",\"tailSeekAttempted\":%s"
        ",\"tailSeekSucceeded\":%s"
        ",\"tailSeekReachedEOF\":%s"
        ",\"format\":",
        full_decode ? "true" : "false",
        inspection.packets_inspected,
        inspection.inspected_packet_bytes,
        inspection.tail_seek_attempted ? "true" : "false",
        inspection.tail_seek_succeeded ? "true" : "false",
        inspection.tail_seek_reached_eof ? "true" : "false"
    );
    illucet_json_string(
        &print,
        input.format->iformat != NULL ? input.format->iformat->name : ""
    );
    av_bprintf(&print, ",\"formatLongName\":");
    illucet_json_string(
        &print,
        input.format->iformat != NULL
            ? input.format->iformat->long_name
            : ""
    );
    av_bprintf(
        &print,
        ",\"duration\":%.6f,\"bitRate\":%" PRId64
        ",\"size\":%" PRId64
        ",\"streamCount\":%zu,\"videoStreamCount\":%d"
        ",\"audioStreamCount\":%d,\"subtitleStreamCount\":%d"
        ",\"artworkCount\":%d,\"metadata\":",
        reported_duration,
        input.format->bit_rate,
        size,
        stream_count,
        video_count,
        audio_count,
        subtitle_count,
        artwork_count
    );
    bool mov_family = input.format->iformat != NULL
        && av_match_name("mov", input.format->iformat->name) > 0;
    illucet_json_dictionary(
        &print,
        input.format->metadata,
        mov_family
    );
    av_bprintf(
        &print,
        ",\"chapterCount\":%u,\"chapters\":[",
        input.format->nb_chapters
    );
    for (unsigned int index = 0; index < input.format->nb_chapters; index++) {
        if (index > 0) {
            av_bprint_chars(&print, ',', 1);
        }
        AVChapter *chapter = input.format->chapters[index];
        const AVDictionaryEntry *title = av_dict_get(
            chapter->metadata,
            "title",
            NULL,
            0
        );
        av_bprintf(
            &print,
            "{\"start\":%.6f,\"end\":%.6f,\"title\":",
            chapter->start * av_q2d(chapter->time_base),
            chapter->end * av_q2d(chapter->time_base)
        );
        illucet_json_string(
            &print,
            title != NULL && title->value != NULL
                ? title->value
                : "Chapter"
        );
        av_bprint_chars(&print, '}', 1);
    }
    av_bprintf(&print, "]");
    av_bprintf(&print, ",\"streams\":[");
    for (size_t index = 0; index < stream_count; index++) {
        if (index > 0) {
            av_bprint_chars(&print, ',', 1);
        }
        AVStream *stream = input.format->streams[index];
        AVCodecParameters *parameters = stream->codecpar;
        const AVCodecDescriptor *descriptor = avcodec_descriptor_get(
            parameters->codec_id
        );
        AVRational frame_rate = parameters->codec_type == AVMEDIA_TYPE_VIDEO
            ? av_guess_frame_rate(input.format, stream, NULL)
            : (AVRational){0, 1};
        double stream_duration = stream->duration != AV_NOPTS_VALUE
            ? stream->duration * av_q2d(stream->time_base)
            : -1.0;
        char channel_layout[128] = {0};
        if (parameters->codec_type == AVMEDIA_TYPE_AUDIO) {
            av_channel_layout_describe(
                &parameters->ch_layout,
                channel_layout,
                sizeof(channel_layout)
            );
        }
        av_bprintf(&print, "{\"index\":%zu,\"type\":", index);
        illucet_json_string(&print, illucet_stream_type(stream));
        av_bprintf(&print, ",\"codec\":");
        illucet_json_string(&print, avcodec_get_name(parameters->codec_id));
        av_bprintf(&print, ",\"codecLongName\":");
        illucet_json_string(
            &print,
            descriptor != NULL && descriptor->long_name != NULL
                ? descriptor->long_name
                : ""
        );
        av_bprintf(
            &print,
            ",\"duration\":%.6f,\"bitRate\":%" PRId64
            ",\"attachedPicture\":%s,\"isDefault\":%s,\"forced\":%s"
            ",\"decodedFrames\":%" PRId64
            ",\"width\":%d,\"height\":%d,\"frameRate\":%.6f"
            ",\"sampleRate\":%d,\"channels\":%d,\"channelLayout\":",
            stream_duration,
            parameters->bit_rate,
            (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
                ? "true"
                : "false",
            (stream->disposition & AV_DISPOSITION_DEFAULT) != 0
                ? "true"
                : "false",
            (stream->disposition & AV_DISPOSITION_FORCED) != 0
                ? "true"
                : "false",
            needs_decoders ? decoded_frames[index] : 0,
            parameters->width,
            parameters->height,
            frame_rate.den != 0 ? av_q2d(frame_rate) : 0.0,
            parameters->sample_rate,
            parameters->ch_layout.nb_channels
        );
        illucet_json_string(&print, channel_layout);
        av_bprintf(&print, ",\"pixelFormat\":");
        const char *pixel_format = parameters->codec_type
                == AVMEDIA_TYPE_VIDEO
            ? av_get_pix_fmt_name(
                (enum AVPixelFormat)parameters->format
            )
            : NULL;
        illucet_json_string(
            &print,
            pixel_format != NULL ? pixel_format : ""
        );
        av_bprintf(&print, ",\"colorSpace\":");
        const char *color_space = av_color_space_name(
            parameters->color_space
        );
        illucet_json_string(
            &print,
            color_space != NULL ? color_space : ""
        );
        av_bprintf(&print, ",\"colorTransfer\":");
        const char *color_transfer = av_color_transfer_name(
            parameters->color_trc
        );
        illucet_json_string(
            &print,
            color_transfer != NULL ? color_transfer : ""
        );
        av_bprintf(&print, ",\"colorPrimaries\":");
        const char *color_primaries = av_color_primaries_name(
            parameters->color_primaries
        );
        illucet_json_string(
            &print,
            color_primaries != NULL ? color_primaries : ""
        );
        av_bprintf(&print, ",\"colorRange\":");
        const char *color_range = av_color_range_name(
            parameters->color_range
        );
        illucet_json_string(
            &print,
            color_range != NULL ? color_range : ""
        );
        av_bprintf(
            &print,
            ",\"isHDR\":%s",
            illucet_video_parameters_are_hdr(parameters)
                ? "true"
                : "false"
        );
        av_bprintf(
            &print,
            ",\"decodedSampleWindows\":%d,\"packetSHA256\":\"",
            bounded_strong
                ? inspection.decoded_sample_windows[index]
                : 0
        );
        if (full_decode) {
            for (int byte = 0; byte < 32; byte++) {
                av_bprintf(&print, "%02x", packet_digests[index][byte]);
            }
        }
        av_bprint_chars(&print, '"', 1);
        av_bprintf(&print, ",\"metadata\":");
        illucet_json_dictionary(&print, stream->metadata, false);
        av_bprint_chars(&print, '}', 1);
    }
    av_bprintf(&print, "]}");
    if (!av_bprint_is_complete(&print)) {
        av_bprint_finalize(&print, NULL);
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Probe JSON exceeded its 2 MiB bound"
        );
        goto cleanup;
    }
    av_bprint_finalize(&print, result_json);
    if (*result_json == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot finalize probe JSON"
        );
        goto cleanup;
    }
    illucet_progress(job, "probe", 1.0);
    status = ILLUCET_FFMPEG_OK;

cleanup:
    av_packet_free(&packet);
    av_frame_free(&frame);
    if (decoders != NULL) {
        for (size_t index = 0; index < stream_count; index++) {
            avcodec_free_context(&decoders[index]);
        }
    }
    av_free(decoders);
    av_free(decoded_frames);
    if (packet_hashers != NULL) {
        for (size_t index = 0; index < stream_count; index++) {
            av_free(packet_hashers[index]);
        }
    }
    av_free(packet_hashers);
    av_free(packet_digests);
    av_free(stream_packets);
    illucet_close_input(&input);
    if (status != ILLUCET_FFMPEG_OK && result_json != NULL) {
        av_freep(result_json);
    }
    return status;
}

IllucetFFmpegStatus illucet_ffmpeg_probe_json(
    const char *input_path,
    IllucetFFmpegJob *job,
    char **result_json,
    char **error
) {
    return illucet_ffmpeg_probe_json_with_class(
        input_path,
        ILLUCET_FFMPEG_PROBE_STRONG_FULL_DECODE,
        job,
        result_json,
        error
    );
}
