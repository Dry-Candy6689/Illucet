#include "IllucetFFmpegBridgeInternal.h"

#define ILLUCET_MAX_EMBEDDED_SUBTITLE_CUES 20000
#define ILLUCET_MAX_EMBEDDED_SUBTITLE_BYTES (4 * 1024 * 1024)
#define ILLUCET_MAX_ENCODED_SUBTITLE_PACKET (1024 * 1024)

typedef struct IllucetEncodedSubtitleSet {
    AVPacket **packets;
    size_t count;
    size_t capacity;
    size_t total_bytes;
} IllucetEncodedSubtitleSet;

static enum AVCodecID illucet_subtitle_codec_id(IllucetSubtitleCodec codec) {
    switch (codec) {
        case ILLUCET_SUBTITLE_CODEC_MOV_TEXT:
            return AV_CODEC_ID_MOV_TEXT;
        case ILLUCET_SUBTITLE_CODEC_SUBRIP:
            return AV_CODEC_ID_SUBRIP;
        case ILLUCET_SUBTITLE_CODEC_WEBVTT:
            return AV_CODEC_ID_WEBVTT;
    }
    return AV_CODEC_ID_NONE;
}

static bool illucet_subtitle_request_is_compatible(
    const IllucetSubtitleMuxRequest *request
) {
    if (request == NULL) {
        return false;
    }
    switch (request->container) {
        case ILLUCET_MEDIA_CONTAINER_MP4:
        case ILLUCET_MEDIA_CONTAINER_MOV:
            return request->codec == ILLUCET_SUBTITLE_CODEC_MOV_TEXT;
        case ILLUCET_MEDIA_CONTAINER_MATROSKA:
            return request->codec == ILLUCET_SUBTITLE_CODEC_SUBRIP;
        case ILLUCET_MEDIA_CONTAINER_WEBM:
            return request->codec == ILLUCET_SUBTITLE_CODEC_WEBVTT;
        default:
            return false;
    }
}

static bool illucet_bounded_subtitle_text(
    const char *value,
    size_t maximum
) {
    return value == NULL || strnlen(value, maximum + 1) <= maximum;
}

static void illucet_free_encoded_subtitles(IllucetEncodedSubtitleSet *set) {
    if (set == NULL) {
        return;
    }
    for (size_t index = 0; index < set->count; index++) {
        av_packet_free(&set->packets[index]);
    }
    av_freep(&set->packets);
    memset(set, 0, sizeof(*set));
}

static int illucet_compare_subtitle_packets(const void *left, const void *right) {
    const AVPacket *first = *(AVPacket *const *)left;
    const AVPacket *second = *(AVPacket *const *)right;
    int64_t first_pts = first->pts == AV_NOPTS_VALUE
        ? INT64_MAX
        : first->pts;
    int64_t second_pts = second->pts == AV_NOPTS_VALUE
        ? INT64_MAX
        : second->pts;
    return first_pts < second_pts ? -1 : first_pts > second_pts ? 1 : 0;
}

static IllucetFFmpegStatus illucet_append_encoded_subtitle(
    IllucetEncodedSubtitleSet *set,
    AVPacket *packet,
    char **error
) {
    if (
        set->count >= ILLUCET_MAX_EMBEDDED_SUBTITLE_CUES
        || packet->size <= 0
        || (size_t)packet->size > ILLUCET_MAX_ENCODED_SUBTITLE_PACKET
        || set->total_bytes
            > ILLUCET_MAX_EMBEDDED_SUBTITLE_BYTES - (size_t)packet->size
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INPUT_ERROR,
            error,
            "Embedded subtitle input exceeded its bounded cue or byte limit"
        );
    }
    if (set->count == set->capacity) {
        size_t next = set->capacity == 0 ? 64 : set->capacity * 2;
        if (next > ILLUCET_MAX_EMBEDDED_SUBTITLE_CUES) {
            next = ILLUCET_MAX_EMBEDDED_SUBTITLE_CUES;
        }
        AVPacket **resized = av_realloc_array(
            set->packets,
            next,
            sizeof(*resized)
        );
        if (resized == NULL) {
            return illucet_error(
                ILLUCET_FFMPEG_OUT_OF_MEMORY,
                error,
                "Cannot allocate embedded subtitle packet state"
            );
        }
        set->packets = resized;
        set->capacity = next;
    }
    set->packets[set->count++] = packet;
    set->total_bytes += (size_t)packet->size;
    return ILLUCET_FFMPEG_OK;
}

static IllucetFFmpegStatus illucet_encode_subtitle(
    AVSubtitle *subtitle,
    int64_t fallback_pts,
    AVRational fallback_time_base,
    AVCodecContext *encoder,
    AVStream *output_stream,
    IllucetEncodedSubtitleSet *set,
    char **error
) {
    if (subtitle->num_rects == 0) {
        return ILLUCET_FFMPEG_OK;
    }
    int64_t base_pts = subtitle->pts;
    if (base_pts == AV_NOPTS_VALUE && fallback_pts != AV_NOPTS_VALUE) {
        base_pts = av_rescale_q(
            fallback_pts,
            fallback_time_base,
            AV_TIME_BASE_Q
        );
    }
    if (base_pts == AV_NOPTS_VALUE) {
        return illucet_error(
            ILLUCET_FFMPEG_INPUT_ERROR,
            error,
            "Embedded subtitle cue has no timestamp"
        );
    }
    if (subtitle->end_display_time <= subtitle->start_display_time) {
        return illucet_error(
            ILLUCET_FFMPEG_INPUT_ERROR,
            error,
            "Embedded subtitle cue has an invalid duration"
        );
    }
    uint32_t duration =
        subtitle->end_display_time - subtitle->start_display_time;
    int64_t start_microseconds = av_rescale_q(
        subtitle->start_display_time,
        (AVRational){1, 1000},
        AV_TIME_BASE_Q
    );
    subtitle->pts = base_pts + start_microseconds;
    subtitle->start_display_time = 0;
    subtitle->end_display_time = duration;

    AVPacket *packet = av_packet_alloc();
    if (
        packet == NULL
        || av_new_packet(packet, ILLUCET_MAX_ENCODED_SUBTITLE_PACKET) < 0
    ) {
        av_packet_free(&packet);
        return illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate encoded subtitle packet"
        );
    }
    int encoded = avcodec_encode_subtitle(
        encoder,
        packet->data,
        packet->size,
        subtitle
    );
    if (encoded < 0) {
        av_packet_free(&packet);
        return illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            encoded,
            "Cannot encode embedded subtitle cue"
        );
    }
    if (encoded == 0) {
        av_packet_free(&packet);
        return ILLUCET_FFMPEG_OK;
    }
    av_shrink_packet(packet, encoded);
    packet->stream_index = output_stream->index;
    packet->pts = av_rescale_q(
        subtitle->pts,
        AV_TIME_BASE_Q,
        output_stream->time_base
    );
    packet->dts = packet->pts;
    packet->duration = av_rescale_q(
        duration,
        (AVRational){1, 1000},
        output_stream->time_base
    );
    packet->pos = -1;
    IllucetFFmpegStatus status = illucet_append_encoded_subtitle(
        set,
        packet,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        av_packet_free(&packet);
    }
    return status;
}

static IllucetFFmpegStatus illucet_collect_encoded_subtitles(
    IllucetInput *input,
    int stream_index,
    AVCodecContext *decoder,
    AVCodecContext *encoder,
    AVStream *output_stream,
    IllucetFFmpegJob *job,
    IllucetEncodedSubtitleSet *set,
    char **error
) {
    AVPacket *packet = av_packet_alloc();
    if (packet == NULL) {
        return illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate subtitle input packet"
        );
    }
    IllucetFFmpegStatus status = ILLUCET_FFMPEG_OK;
    while (true) {
        int result = av_read_frame(input->format, packet);
        if (result == AVERROR_EOF) {
            break;
        }
        if (result < 0) {
            status = illucet_job_cancelled(job)
                ? illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled")
                : illucet_av_error(
                    ILLUCET_FFMPEG_INPUT_ERROR,
                    error,
                    result,
                    "Cannot read embedded subtitle input"
                );
            break;
        }
        if (packet->stream_index != stream_index) {
            av_packet_unref(packet);
            continue;
        }
        int64_t packet_pts = packet->pts;
        AVSubtitle subtitle;
        memset(&subtitle, 0, sizeof(subtitle));
        int got_subtitle = 0;
        result = avcodec_decode_subtitle2(
            decoder,
            &subtitle,
            &got_subtitle,
            packet
        );
        av_packet_unref(packet);
        if (result < 0) {
            avsubtitle_free(&subtitle);
            status = illucet_av_error(
                ILLUCET_FFMPEG_INPUT_ERROR,
                error,
                result,
                "Cannot decode embedded subtitle input"
            );
            break;
        }
        if (got_subtitle) {
            status = illucet_encode_subtitle(
                &subtitle,
                packet_pts,
                input->format->streams[stream_index]->time_base,
                encoder,
                output_stream,
                set,
                error
            );
        }
        avsubtitle_free(&subtitle);
        if (status != ILLUCET_FFMPEG_OK) {
            break;
        }
        if (illucet_job_cancelled(job)) {
            status = illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
            break;
        }
    }
    av_packet_free(&packet);
    if (status == ILLUCET_FFMPEG_OK && set->count == 0) {
        status = illucet_error(
            ILLUCET_FFMPEG_INPUT_ERROR,
            error,
            "Embedded subtitle input contained no cues"
        );
    }
    if (status == ILLUCET_FFMPEG_OK) {
        qsort(
            set->packets,
            set->count,
            sizeof(*set->packets),
            illucet_compare_subtitle_packets
        );
    }
    return status;
}

static IllucetFFmpegStatus illucet_write_pending_subtitles(
    AVFormatContext *output,
    IllucetEncodedSubtitleSet *set,
    size_t *index,
    AVStream *subtitle_stream,
    int64_t media_timestamp,
    AVRational media_time_base,
    bool flush_all,
    char **error
) {
    while (*index < set->count) {
        AVPacket *packet = set->packets[*index];
        if (
            !flush_all
            && media_timestamp != AV_NOPTS_VALUE
            && av_compare_ts(
                packet->pts,
                subtitle_stream->time_base,
                media_timestamp,
                media_time_base
            ) > 0
        ) {
            break;
        }
        int result = av_interleaved_write_frame(output, packet);
        if (result < 0) {
            return illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot write embedded subtitle packet"
            );
        }
        (*index)++;
    }
    return ILLUCET_FFMPEG_OK;
}

IllucetFFmpegStatus illucet_ffmpeg_embed_subtitle(
    const char *media_input,
    const char *subtitle_input,
    const char *output_path,
    const IllucetSubtitleMuxRequest *request,
    IllucetFFmpegJob *job,
    char **error
) {
    illucet_clear_error(error);
    if (
        !illucet_path_is_valid(media_input)
        || !illucet_path_is_valid(subtitle_input)
        || !illucet_path_is_valid(output_path)
        || !illucet_subtitle_request_is_compatible(request)
        || !illucet_bounded_subtitle_text(request->language, 128)
        || !illucet_bounded_subtitle_text(request->title, 256)
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "A valid bounded subtitle mux request is required"
        );
    }
    if (illucet_progress(job, "subtitle-embed", 0.0)) {
        return illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
    }

    IllucetInput media;
    IllucetInput subtitle;
    memset(&media, 0, sizeof(media));
    memset(&subtitle, 0, sizeof(subtitle));
    IllucetPartialOutput partial;
    memset(&partial, 0, sizeof(partial));
    AVFormatContext *output = NULL;
    AVCodecContext *decoder = NULL;
    AVCodecContext *encoder = NULL;
    AVPacket *media_packet = NULL;
    int *stream_map = NULL;
    IllucetEncodedSubtitleSet encoded;
    memset(&encoded, 0, sizeof(encoded));

    IllucetFFmpegStatus status = illucet_open_input(
        media_input,
        job,
        &media,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    status = illucet_open_input(
        subtitle_input,
        job,
        &subtitle,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }
    int subtitle_index = av_find_best_stream(
        subtitle.format,
        AVMEDIA_TYPE_SUBTITLE,
        -1,
        -1,
        NULL,
        0
    );
    if (subtitle_index < 0) {
        status = illucet_error(
            ILLUCET_FFMPEG_INPUT_ERROR,
            error,
            "Subtitle input has no decodable text stream"
        );
        goto cleanup;
    }
    enum AVCodecID output_codec_id = illucet_subtitle_codec_id(request->codec);
    const AVCodec *decoder_codec = avcodec_find_decoder(
        subtitle.format->streams[subtitle_index]->codecpar->codec_id
    );
    const AVCodec *encoder_codec = avcodec_find_encoder(output_codec_id);
    if (decoder_codec == NULL || encoder_codec == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            "Required subtitle decoder or encoder is unavailable"
        );
        goto cleanup;
    }
    decoder = avcodec_alloc_context3(decoder_codec);
    encoder = avcodec_alloc_context3(encoder_codec);
    if (decoder == NULL || encoder == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate subtitle codec contexts"
        );
        goto cleanup;
    }
    int result = avcodec_parameters_to_context(
        decoder,
        subtitle.format->streams[subtitle_index]->codecpar
    );
    if (result >= 0) {
        decoder->pkt_timebase =
            subtitle.format->streams[subtitle_index]->time_base;
        result = avcodec_open2(decoder, decoder_codec, NULL);
    }
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            result,
            "Cannot open subtitle decoder"
        );
        goto cleanup;
    }
    encoder->time_base = (AVRational){1, 1000};
    if (decoder->subtitle_header_size > 0) {
        encoder->subtitle_header = av_memdup(
            decoder->subtitle_header,
            (size_t)decoder->subtitle_header_size
        );
        if (encoder->subtitle_header == NULL) {
            status = illucet_error(
                ILLUCET_FFMPEG_OUT_OF_MEMORY,
                error,
                "Cannot copy subtitle codec header"
            );
            goto cleanup;
        }
        encoder->subtitle_header_size = decoder->subtitle_header_size;
    }
    result = avcodec_open2(encoder, encoder_codec, NULL);
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            result,
            "Cannot open subtitle encoder"
        );
        goto cleanup;
    }

    status = illucet_alloc_output(
        output_path,
        illucet_container_format_name(request->container),
        &partial,
        &output,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }
    if (
        avformat_query_codec(
            output->oformat,
            output_codec_id,
            FF_COMPLIANCE_NORMAL
        ) <= 0
    ) {
        status = illucet_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            "The requested container does not support the subtitle codec"
        );
        goto cleanup;
    }
    stream_map = av_calloc(media.format->nb_streams, sizeof(*stream_map));
    if (stream_map == NULL && media.format->nb_streams > 0) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate subtitle mux stream map"
        );
        goto cleanup;
    }
    bool has_media = false;
    for (unsigned int index = 0; index < media.format->nb_streams; index++) {
        AVStream *input_stream = media.format->streams[index];
        if (
            input_stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO
            || input_stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO
        ) {
            has_media = true;
        }
        if (
            avformat_query_codec(
                output->oformat,
                input_stream->codecpar->codec_id,
                FF_COMPLIANCE_NORMAL
            ) <= 0
        ) {
            status = illucet_error(
                ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
                error,
                "An existing media stream is incompatible with the output container"
            );
            goto cleanup;
        }
        AVStream *output_stream = avformat_new_stream(output, NULL);
        if (output_stream == NULL) {
            status = illucet_error(
                ILLUCET_FFMPEG_OUT_OF_MEMORY,
                error,
                "Cannot allocate copied media stream"
            );
            goto cleanup;
        }
        result = avcodec_parameters_copy(
            output_stream->codecpar,
            input_stream->codecpar
        );
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot copy media stream parameters"
            );
            goto cleanup;
        }
        output_stream->codecpar->codec_tag = 0;
        output_stream->time_base = input_stream->time_base;
        output_stream->disposition = input_stream->disposition;
        av_dict_copy(&output_stream->metadata, input_stream->metadata, 0);
        stream_map[index] = output_stream->index;
    }
    if (!has_media) {
        status = illucet_error(
            ILLUCET_FFMPEG_INPUT_ERROR,
            error,
            "Subtitle embedding requires an audio or video media stream"
        );
        goto cleanup;
    }
    AVStream *subtitle_stream = avformat_new_stream(output, NULL);
    if (subtitle_stream == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate embedded subtitle stream"
        );
        goto cleanup;
    }
    result = avcodec_parameters_from_context(
        subtitle_stream->codecpar,
        encoder
    );
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot prepare embedded subtitle stream"
        );
        goto cleanup;
    }
    subtitle_stream->codecpar->codec_tag = 0;
    subtitle_stream->time_base = encoder->time_base;
    subtitle_stream->disposition =
        (request->is_default ? AV_DISPOSITION_DEFAULT : 0)
        | (request->is_forced ? AV_DISPOSITION_FORCED : 0);
    if (request->language != NULL && request->language[0] != '\0') {
        av_dict_set(
            &subtitle_stream->metadata,
            "language",
            request->language,
            0
        );
    }
    if (request->title != NULL && request->title[0] != '\0') {
        av_dict_set(
            &subtitle_stream->metadata,
            "title",
            request->title,
            0
        );
        av_dict_set(
            &subtitle_stream->metadata,
            "handler_name",
            request->title,
            0
        );
    }
    av_dict_set(
        &subtitle_stream->metadata,
        "illucet_automatic",
        request->automatic ? "1" : "0",
        0
    );
    illucet_apply_metadata(
        output,
        media.format,
        &request->metadata,
        request->container,
        "Illucet subtitle mux"
    );
    result = illucet_write_output_header(
        output,
        request->container,
        request->fast_start,
        true
    );
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot write subtitle output header"
        );
        goto cleanup;
    }

    status = illucet_collect_encoded_subtitles(
        &subtitle,
        subtitle_index,
        decoder,
        encoder,
        subtitle_stream,
        job,
        &encoded,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }
    media_packet = av_packet_alloc();
    if (media_packet == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate media mux packet"
        );
        goto cleanup;
    }
    size_t subtitle_packet_index = 0;
    double duration = illucet_duration_seconds(media.format);
    while (true) {
        result = av_read_frame(media.format, media_packet);
        if (result == AVERROR_EOF) {
            break;
        }
        if (result < 0) {
            status = illucet_job_cancelled(job)
                ? illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled")
                : illucet_av_error(
                    ILLUCET_FFMPEG_INPUT_ERROR,
                    error,
                    result,
                    "Cannot read media for subtitle embedding"
                );
            goto cleanup;
        }
        AVStream *input_stream =
            media.format->streams[media_packet->stream_index];
        int64_t progress_timestamp = illucet_packet_timestamp(media_packet);
        status = illucet_write_pending_subtitles(
            output,
            &encoded,
            &subtitle_packet_index,
            subtitle_stream,
            progress_timestamp,
            input_stream->time_base,
            false,
            error
        );
        if (status != ILLUCET_FFMPEG_OK) {
            goto cleanup;
        }
        AVStream *output_stream =
            output->streams[stream_map[media_packet->stream_index]];
        av_packet_rescale_ts(
            media_packet,
            input_stream->time_base,
            output_stream->time_base
        );
        media_packet->stream_index = output_stream->index;
        media_packet->pos = -1;
        result = av_interleaved_write_frame(output, media_packet);
        av_packet_unref(media_packet);
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot write media during subtitle embedding"
            );
            goto cleanup;
        }
        double progress = duration > 0.0
            ? progress_timestamp * av_q2d(input_stream->time_base) / duration
            : -1.0;
        if (
            illucet_progress(
                job,
                "subtitle-embed",
                illucet_intermediate_progress(progress)
            )
        ) {
            status = illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
            goto cleanup;
        }
    }
    status = illucet_write_pending_subtitles(
        output,
        &encoded,
        &subtitle_packet_index,
        subtitle_stream,
        AV_NOPTS_VALUE,
        (AVRational){1, 1},
        true,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }
    result = av_write_trailer(output);
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot finalize embedded subtitles"
        );
        goto cleanup;
    }
    illucet_free_output(&output, &partial, false);
    status = illucet_partial_commit(&partial, error);
    if (status == ILLUCET_FFMPEG_OK) {
        illucet_progress(job, "subtitle-embed", 1.0);
    }

cleanup:
    av_packet_free(&media_packet);
    illucet_free_encoded_subtitles(&encoded);
    av_free(stream_map);
    avcodec_free_context(&decoder);
    avcodec_free_context(&encoder);
    illucet_close_input(&subtitle);
    illucet_close_input(&media);
    if (output != NULL) {
        illucet_free_output(&output, &partial, true);
    }
    return status;
}
