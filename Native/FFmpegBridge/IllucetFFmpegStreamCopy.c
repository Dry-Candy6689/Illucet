#include "IllucetFFmpegBridgeInternal.h"

typedef struct IllucetRemuxSource {
    IllucetInput *input;
    int input_stream_index;
    int output_stream_index;
    AVPacket *packet;
    bool has_packet;
    bool ended;
    bool drop_discard_packets;
} IllucetRemuxSource;

static int illucet_remux_fetch(IllucetRemuxSource *source) {
    if (source->ended || source->has_packet) {
        return 0;
    }
    if (source->packet == NULL) {
        source->packet = av_packet_alloc();
        if (source->packet == NULL) {
            return AVERROR(ENOMEM);
        }
    }
    while (true) {
        int result = av_read_frame(source->input->format, source->packet);
        if (result == AVERROR_EOF) {
            source->ended = true;
            return 0;
        }
        if (result < 0) {
            return result;
        }
        if (source->packet->stream_index == source->input_stream_index) {
            if (
                source->drop_discard_packets
                && (source->packet->flags & AV_PKT_FLAG_DISCARD)
            ) {
                /*
                 * Metadata republication remuxes AVFoundation output, which
                 * can append discard-timed packets behind later media DTS.
                 * Exclude them before timestamp selection so they cannot
                 * perturb interleaving. Merge leaves this false and retains
                 * every selected packet for exact AAC packet/digest identity.
                 */
                av_packet_unref(source->packet);
                continue;
            }
            /*
             * Preserve every selected-stream payload, including AAC priming
             * packets marked discard by the demuxer. The muxer retains the
             * packet while representing its decode-discard timing metadata.
             */
            source->has_packet = true;
            return 0;
        }
        av_packet_unref(source->packet);
    }
}

static IllucetFFmpegStatus illucet_remux_selected(
    const char *first_path,
    enum AVMediaType first_type,
    const char *second_path,
    enum AVMediaType second_type,
    const char *output_path,
    const char *stage,
    const IllucetStreamCopyRequest *request,
    IllucetFFmpegJob *job,
    char **error
) {
    if (illucet_progress(job, stage, 0.0)) {
        return illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
    }
    IllucetInput inputs[2];
    memset(inputs, 0, sizeof(inputs));
    IllucetRemuxSource sources[2];
    memset(sources, 0, sizeof(sources));
    int source_count = second_path != NULL ? 2 : 1;
    IllucetPartialOutput partial;
    memset(&partial, 0, sizeof(partial));
    AVFormatContext *output = NULL;
    IllucetFFmpegStatus status = illucet_open_input(
        first_path,
        job,
        &inputs[0],
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    if (source_count == 2) {
        status = illucet_open_input(second_path, job, &inputs[1], error);
        if (status != ILLUCET_FFMPEG_OK) {
            illucet_close_input(&inputs[0]);
            return status;
        }
    }
    status = illucet_alloc_output(
        output_path,
        request != NULL
            ? illucet_container_format_name(request->container)
            : NULL,
        &partial,
        &output,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }

    enum AVMediaType types[2] = {first_type, second_type};
    for (int index = 0; index < source_count; index++) {
        int stream_index = av_find_best_stream(
            inputs[index].format,
            types[index],
            -1,
            -1,
            NULL,
            0
        );
        if (stream_index < 0) {
            status = illucet_error(
                ILLUCET_FFMPEG_INPUT_ERROR,
                error,
                "Input has no required %s stream",
                av_get_media_type_string(types[index])
            );
            goto cleanup;
        }
        AVStream *input_stream = inputs[index].format->streams[stream_index];
        AVStream *output_stream = avformat_new_stream(output, NULL);
        if (output_stream == NULL) {
            status = illucet_error(
                ILLUCET_FFMPEG_OUT_OF_MEMORY,
                error,
                "Cannot allocate copied output stream"
            );
            goto cleanup;
        }
        int result = avcodec_parameters_copy(
            output_stream->codecpar,
            input_stream->codecpar
        );
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot copy stream parameters"
            );
            goto cleanup;
        }
        output_stream->codecpar->codec_tag = 0;
        output_stream->time_base = input_stream->time_base;
        if (
            request == NULL
            || request->metadata.preserve_source_metadata
        ) {
            av_dict_copy(
                &output_stream->metadata,
                input_stream->metadata,
                0
            );
        }
        sources[index].input = &inputs[index];
        sources[index].input_stream_index = stream_index;
        sources[index].output_stream_index = output_stream->index;
        sources[index].drop_discard_packets =
            request != NULL
            && request->mode == ILLUCET_STREAM_COPY_REMUX;
    }
    int result;
    if (request != NULL) {
        illucet_apply_metadata(
            output,
            inputs[0].format,
            &request->metadata,
            request->container,
            "Illucet stream copy"
        );
        result = illucet_write_output_header(
            output,
            request->container,
            request->fast_start,
            true
        );
    } else {
        av_dict_copy(&output->metadata, inputs[0].format->metadata, 0);
        av_dict_set(
            &output->metadata,
            "comment",
            "Processed in-process by Illucet",
            0
        );
        result = avformat_write_header(output, NULL);
    }
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot write copied-stream header"
        );
        goto cleanup;
    }

    double duration = illucet_duration_seconds(inputs[0].format);
    if (source_count == 2) {
        duration = fmax(duration, illucet_duration_seconds(inputs[1].format));
    }
    while (true) {
        for (int index = 0; index < source_count; index++) {
            result = illucet_remux_fetch(&sources[index]);
            if (result < 0) {
                if (illucet_job_cancelled(job)) {
                    status = illucet_error(
                        ILLUCET_FFMPEG_CANCELLED,
                        error,
                        "Cancelled"
                    );
                } else {
                    status = illucet_av_error(
                        ILLUCET_FFMPEG_INPUT_ERROR,
                        error,
                        result,
                        "Cannot read selected input stream"
                    );
                }
                goto cleanup;
            }
        }
        int selected = -1;
        for (int index = 0; index < source_count; index++) {
            if (!sources[index].has_packet) {
                continue;
            }
            if (selected < 0) {
                selected = index;
                continue;
            }
            AVStream *candidate_stream =
                inputs[index].format->streams[sources[index].input_stream_index];
            AVStream *selected_stream =
                inputs[selected].format->streams[sources[selected].input_stream_index];
            if (av_compare_ts(
                    illucet_packet_timestamp(sources[index].packet),
                    candidate_stream->time_base,
                    illucet_packet_timestamp(sources[selected].packet),
                    selected_stream->time_base
                ) < 0) {
                selected = index;
            }
        }
        if (selected < 0) {
            break;
        }
        IllucetRemuxSource *source = &sources[selected];
        AVStream *input_stream =
            source->input->format->streams[source->input_stream_index];
        AVStream *output_stream =
            output->streams[source->output_stream_index];
        int64_t progress_timestamp = illucet_packet_timestamp(source->packet);
        av_packet_rescale_ts(
            source->packet,
            input_stream->time_base,
            output_stream->time_base
        );
        source->packet->stream_index = source->output_stream_index;
        source->packet->pos = -1;
        result = av_interleaved_write_frame(output, source->packet);
        av_packet_unref(source->packet);
        source->has_packet = false;
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot write copied packet"
            );
            goto cleanup;
        }
        double progress = -1.0;
        if (duration > 0.0) {
            progress =
                progress_timestamp * av_q2d(input_stream->time_base) / duration;
        }
        if (illucet_progress(job, stage, illucet_intermediate_progress(progress))) {
            status = illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
            goto cleanup;
        }
    }
    result = av_write_trailer(output);
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot finalize copied streams"
        );
        goto cleanup;
    }
    illucet_free_output(&output, &partial, false);
    status = illucet_partial_commit(&partial, error);
    if (status == ILLUCET_FFMPEG_OK) {
        illucet_progress(job, stage, 1.0);
    }

cleanup:
    for (int index = 0; index < source_count; index++) {
        av_packet_free(&sources[index].packet);
        illucet_close_input(&inputs[index]);
    }
    if (output != NULL) {
        illucet_free_output(&output, &partial, true);
    }
    return status;
}

IllucetFFmpegStatus illucet_ffmpeg_stream_copy(
    const char *first_input,
    const char *second_input,
    const char *output,
    const IllucetStreamCopyRequest *request,
    IllucetFFmpegJob *job,
    char **error
) {
    illucet_clear_error(error);
    if (
        request == NULL
        || illucet_container_format_name(request->container) == NULL
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "A valid typed stream-copy request is required"
        );
    }
    switch (request->mode) {
        case ILLUCET_STREAM_COPY_MERGE:
            if (!illucet_path_is_valid(second_input)) {
                return illucet_error(
                    ILLUCET_FFMPEG_INVALID_ARGUMENT,
                    error,
                    "Merge stream copy requires two inputs"
                );
            }
            return illucet_remux_selected(
                first_input,
                AVMEDIA_TYPE_VIDEO,
                second_input,
                AVMEDIA_TYPE_AUDIO,
                output,
                "merge",
                request,
                job,
                error
            );
        case ILLUCET_STREAM_COPY_REMUX:
            return illucet_remux_selected(
                first_input,
                AVMEDIA_TYPE_VIDEO,
                first_input,
                AVMEDIA_TYPE_AUDIO,
                output,
                "remux",
                request,
                job,
                error
            );
        case ILLUCET_STREAM_COPY_EXTRACT_AUDIO:
            return illucet_remux_selected(
                first_input,
                AVMEDIA_TYPE_AUDIO,
                NULL,
                AVMEDIA_TYPE_UNKNOWN,
                output,
                "audio-copy",
                request,
                job,
                error
            );
        case ILLUCET_STREAM_COPY_VIDEO_ONLY:
            return illucet_remux_selected(
                first_input,
                AVMEDIA_TYPE_VIDEO,
                NULL,
                AVMEDIA_TYPE_UNKNOWN,
                output,
                "video-only",
                request,
                job,
                error
            );
    }
    return illucet_error(
        ILLUCET_FFMPEG_INVALID_ARGUMENT,
        error,
        "The stream-copy mode is unavailable"
    );
}

IllucetFFmpegStatus illucet_ffmpeg_merge_stream_copy(
    const char *video_input,
    const char *audio_input,
    const char *output,
    IllucetFFmpegJob *job,
    char **error
) {
    illucet_clear_error(error);
    return illucet_remux_selected(
        video_input,
        AVMEDIA_TYPE_VIDEO,
        audio_input,
        AVMEDIA_TYPE_AUDIO,
        output,
        "merge",
        NULL,
        job,
        error
    );
}

IllucetFFmpegStatus illucet_ffmpeg_remux_stream_copy(
    const char *input,
    const char *output,
    IllucetFFmpegJob *job,
    char **error
) {
    illucet_clear_error(error);
    return illucet_remux_selected(
        input,
        AVMEDIA_TYPE_VIDEO,
        input,
        AVMEDIA_TYPE_AUDIO,
        output,
        "remux",
        NULL,
        job,
        error
    );
}

IllucetFFmpegStatus illucet_ffmpeg_extract_audio_copy(
    const char *input,
    const char *output,
    IllucetFFmpegJob *job,
    char **error
) {
    illucet_clear_error(error);
    return illucet_remux_selected(
        input,
        AVMEDIA_TYPE_AUDIO,
        NULL,
        AVMEDIA_TYPE_UNKNOWN,
        output,
        "audio-copy",
        NULL,
        job,
        error
    );
}

IllucetFFmpegStatus illucet_ffmpeg_copy_video_only(
    const char *input,
    const char *output,
    IllucetFFmpegJob *job,
    char **error
) {
    illucet_clear_error(error);
    return illucet_remux_selected(
        input,
        AVMEDIA_TYPE_VIDEO,
        NULL,
        AVMEDIA_TYPE_UNKNOWN,
        output,
        "video-only",
        NULL,
        job,
        error
    );
}
