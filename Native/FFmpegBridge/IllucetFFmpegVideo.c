#include "IllucetFFmpegBridgeInternal.h"

typedef struct IllucetVideoTranscode {
    AVCodecContext *decoder;
    AVCodecContext *encoder;
    AVStream *input_stream;
    AVStream *output_stream;
    AVFormatContext *output;
    struct SwsContext *scaler;
    int64_t next_pts;
    bool force_constant_frame_rate;
} IllucetVideoTranscode;

static int illucet_video_transcode_received(
    IllucetVideoTranscode *transcode,
    AVFrame *decoded
) {
    transcode->scaler = sws_getCachedContext(
        transcode->scaler,
        decoded->width,
        decoded->height,
        (enum AVPixelFormat)decoded->format,
        transcode->encoder->width,
        transcode->encoder->height,
        transcode->encoder->pix_fmt,
        SWS_BILINEAR,
        NULL,
        NULL,
        NULL
    );
    if (transcode->scaler == NULL) {
        return AVERROR(ENOMEM);
    }
    AVFrame *converted = av_frame_alloc();
    if (converted == NULL) {
        return AVERROR(ENOMEM);
    }
    converted->format = transcode->encoder->pix_fmt;
    converted->width = transcode->encoder->width;
    converted->height = transcode->encoder->height;
    converted->color_range = decoded->color_range;
    converted->colorspace = decoded->colorspace;
    converted->color_primaries = decoded->color_primaries;
    converted->color_trc = decoded->color_trc;
    int result = av_frame_get_buffer(converted, 32);
    if (result >= 0) {
        result = av_frame_make_writable(converted);
    }
    if (result >= 0) {
        int rows = sws_scale(
            transcode->scaler,
            (const uint8_t * const *)decoded->data,
            decoded->linesize,
            0,
            decoded->height,
            converted->data,
            converted->linesize
        );
        if (rows != transcode->encoder->height) {
            result = AVERROR_INVALIDDATA;
        }
    }
    if (result >= 0) {
        int64_t timestamp = decoded->best_effort_timestamp;
        int64_t target_pts = timestamp == AV_NOPTS_VALUE
            ? transcode->next_pts
            : av_rescale_q(
                timestamp,
                transcode->input_stream->time_base,
                transcode->encoder->time_base
            );
        if (target_pts < 0) {
            target_pts = 0;
        }
        if (!transcode->force_constant_frame_rate) {
            converted->pts = target_pts < transcode->next_pts
                ? transcode->next_pts
                : target_pts;
            transcode->next_pts = converted->pts + 1;
            result = illucet_write_encoded_packets(
                transcode->encoder,
                transcode->output_stream,
                transcode->output,
                converted
            );
        } else if (target_pts >= transcode->next_pts) {
            int emitted = 0;
            while (transcode->next_pts <= target_pts && emitted < 240) {
                converted->pts = transcode->next_pts++;
                result = illucet_write_encoded_packets(
                    transcode->encoder,
                    transcode->output_stream,
                    transcode->output,
                    converted
                );
                if (result < 0) {
                    break;
                }
                emitted++;
            }
            if (result >= 0 && transcode->next_pts <= target_pts) {
                result = AVERROR_INVALIDDATA;
            }
        }
    }
    av_frame_free(&converted);
    return result;
}

static int illucet_video_decoder_drain(
    IllucetVideoTranscode *transcode,
    AVFrame *frame,
    IllucetFFmpegJob *job,
    double duration
) {
    while (true) {
        int result = avcodec_receive_frame(transcode->decoder, frame);
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
            return 0;
        }
        if (result < 0) {
            return result;
        }
        int64_t timestamp = frame->best_effort_timestamp;
        result = illucet_video_transcode_received(transcode, frame);
        av_frame_unref(frame);
        if (result < 0) {
            return result;
        }
        double progress = -1.0;
        if (duration > 0.0 && timestamp != AV_NOPTS_VALUE) {
            progress =
                timestamp
                * av_q2d(transcode->input_stream->time_base)
                / duration;
        }
        if (illucet_progress(
                job,
                "video-transcode",
                illucet_intermediate_progress(progress)
            )) {
            return AVERROR_EXIT;
        }
    }
}

static bool illucet_video_container_compatible(
    IllucetVideoCodec codec,
    IllucetMediaContainer container
) {
    if (codec != ILLUCET_VIDEO_CODEC_H264 && codec != ILLUCET_VIDEO_CODEC_HEVC) {
        return false;
    }
    return container == ILLUCET_MEDIA_CONTAINER_MP4
        || container == ILLUCET_MEDIA_CONTAINER_MOV
        || container == ILLUCET_MEDIA_CONTAINER_MATROSKA;
}

static bool illucet_video_container_supports_audio(
    IllucetMediaContainer container,
    enum AVCodecID codec
) {
    if (container == ILLUCET_MEDIA_CONTAINER_MATROSKA) {
        return true;
    }
    if (
        container == ILLUCET_MEDIA_CONTAINER_MP4
        || container == ILLUCET_MEDIA_CONTAINER_MOV
    ) {
        return codec == AV_CODEC_ID_AAC
            || codec == AV_CODEC_ID_ALAC
            || codec == AV_CODEC_ID_MP3;
    }
    return false;
}

static bool illucet_video_source_is_hdr(const AVCodecContext *decoder) {
    if (decoder == NULL) {
        return false;
    }
    if (
        decoder->color_trc == AVCOL_TRC_SMPTE2084
        || decoder->color_trc == AVCOL_TRC_ARIB_STD_B67
    ) {
        return true;
    }
    const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(
        decoder->pix_fmt
    );
    return decoder->color_primaries == AVCOL_PRI_BT2020
        && descriptor != NULL
        && descriptor->nb_components > 0
        && descriptor->comp[0].depth > 8;
}

static IllucetFFmpegStatus illucet_validate_video_request(
    const IllucetVideoTranscodeRequest *request,
    char **error
) {
    if (
        request == NULL
        || illucet_container_format_name(request->container) == NULL
        || !illucet_video_container_compatible(
            request->codec,
            request->container
        )
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Unsupported video codec and container combination"
        );
    }
    if (
        request->bitrate_bits_per_second != 0
        && (
            request->bitrate_bits_per_second < 100000
            || request->bitrate_bits_per_second > 100000000
        )
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Video bitrate must be preserved or between 100 Kbps and 100 Mbps"
        );
    }
    if (
        (request->width == 0) != (request->height == 0)
        || request->width < 0
        || request->height < 0
        || request->width > 8192
        || request->height > 8192
        || (request->width > 0 && (request->width % 2 != 0))
        || (request->height > 0 && (request->height % 2 != 0))
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Video dimensions must be preserved or supplied as an even width and height"
        );
    }
    if (
        (request->frame_rate_numerator == 0)
            != (request->frame_rate_denominator == 0)
        || request->frame_rate_numerator < 0
        || request->frame_rate_denominator < 0
        || (
            request->frame_rate_numerator > 0
            && (
                request->frame_rate_denominator == 0
                || av_q2d((AVRational){
                    request->frame_rate_numerator,
                    request->frame_rate_denominator
                }) < 1.0
                || av_q2d((AVRational){
                    request->frame_rate_numerator,
                    request->frame_rate_denominator
                }) > 120.0
            )
        )
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Video frame rate must be preserved or between 1 and 120 fps"
        );
    }
    if (
        request->dynamic_range != ILLUCET_DYNAMIC_RANGE_PRESERVE
        && request->dynamic_range != ILLUCET_DYNAMIC_RANGE_TO_SDR
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Unknown video dynamic-range policy"
        );
    }
    if (request->dynamic_range == ILLUCET_DYNAMIC_RANGE_TO_SDR) {
        return illucet_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            "The pinned native build has no verified HDR-to-SDR path"
        );
    }
    if (
        request->acceleration != ILLUCET_HARDWARE_ACCELERATION_AUTOMATIC
        && request->acceleration
            != ILLUCET_HARDWARE_ACCELERATION_PREFER_VIDEOTOOLBOX
        && request->acceleration != ILLUCET_HARDWARE_ACCELERATION_SOFTWARE_ONLY
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Unknown video acceleration policy"
        );
    }
    return ILLUCET_FFMPEG_OK;
}

static int illucet_configure_video_encoder(
    AVFormatContext *output,
    const AVCodecContext *decoder,
    AVRational frame_rate,
    const IllucetVideoTranscodeRequest *request,
    AVCodecContext **encoder,
    IllucetVideoTranscodeReport *report
) {
    const char *videotoolbox_name = request->codec == ILLUCET_VIDEO_CODEC_HEVC
        ? "hevc_videotoolbox"
        : "h264_videotoolbox";
    const char *software_name = request->codec == ILLUCET_VIDEO_CODEC_HEVC
        ? "libx265"
        : "libx264";
    const char *candidate_names[2] = {NULL, NULL};
    bool candidate_is_videotoolbox[2] = {false, false};
    if (request->acceleration == ILLUCET_HARDWARE_ACCELERATION_SOFTWARE_ONLY) {
        candidate_names[0] = software_name;
    } else {
        candidate_names[0] = videotoolbox_name;
        candidate_is_videotoolbox[0] = true;
        if (
            request->acceleration == ILLUCET_HARDWARE_ACCELERATION_AUTOMATIC
        ) {
            candidate_names[1] = software_name;
        }
    }

    int result = AVERROR_ENCODER_NOT_FOUND;
    for (int index = 0; index < 2; index++) {
        const char *name = candidate_names[index];
        if (name == NULL) {
            continue;
        }
        const AVCodec *codec = avcodec_find_encoder_by_name(name);
        if (codec == NULL) {
            continue;
        }
        AVCodecContext *candidate = avcodec_alloc_context3(codec);
        if (candidate == NULL) {
            return AVERROR(ENOMEM);
        }
        candidate->width = request->width > 0
            ? request->width
            : decoder->width;
        candidate->height = request->height > 0
            ? request->height
            : decoder->height;
        candidate->framerate = frame_rate.num > 0
            ? frame_rate
            : (AVRational){ILLUCET_VIDEO_FPS, 1};
        candidate->time_base = av_inv_q(candidate->framerate);
        bool preserve_hdr = request->codec == ILLUCET_VIDEO_CODEC_HEVC
            && illucet_video_source_is_hdr(decoder);
        candidate->pix_fmt = preserve_hdr
            ? AV_PIX_FMT_P010LE
            : AV_PIX_FMT_NV12;
        int64_t default_bit_rate = (int64_t)candidate->width
            * candidate->height
            * candidate->framerate.num
            / candidate->framerate.den;
        if (default_bit_rate < 1200000) {
            default_bit_rate = 1200000;
        } else if (default_bit_rate > 12000000) {
            default_bit_rate = 12000000;
        }
        candidate->bit_rate = request->bitrate_bits_per_second > 0
            ? request->bitrate_bits_per_second
            : default_bit_rate;
        candidate->gop_size = (int)llround(
            2.0 * av_q2d(candidate->framerate)
        );
        candidate->color_range = decoder->color_range;
        candidate->colorspace = decoder->colorspace;
        candidate->color_primaries = decoder->color_primaries;
        candidate->color_trc = decoder->color_trc;
        if (preserve_hdr) {
            candidate->profile = AV_PROFILE_HEVC_MAIN_10;
        }
        if ((output->oformat->flags & AVFMT_GLOBALHEADER) != 0) {
            candidate->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        }
        if (candidate_is_videotoolbox[index]) {
            av_opt_set(candidate->priv_data, "allow_sw", "1", 0);
            av_opt_set(candidate->priv_data, "realtime", "1", 0);
        }
        result = avcodec_open2(candidate, codec, NULL);
        if (result >= 0) {
            *encoder = candidate;
            if (report != NULL) {
                report->used_videotoolbox =
                    candidate_is_videotoolbox[index];
                report->used_software_fallback =
                    !candidate_is_videotoolbox[index]
                    && request->acceleration
                        == ILLUCET_HARDWARE_ACCELERATION_AUTOMATIC;
                snprintf(
                    report->encoder_name,
                    sizeof(report->encoder_name),
                    "%s",
                    name
                );
            }
            return 0;
        }
        avcodec_free_context(&candidate);
    }
    return result < 0 ? result : AVERROR_ENCODER_NOT_FOUND;
}

IllucetFFmpegStatus illucet_ffmpeg_transcode_video(
    const char *input_path,
    const char *output_path,
    const IllucetVideoTranscodeRequest *request,
    IllucetVideoTranscodeReport *report,
    IllucetFFmpegJob *job,
    char **error
) {
    illucet_clear_error(error);
    if (report != NULL) {
        memset(report, 0, sizeof(*report));
    }
    IllucetFFmpegStatus status = illucet_validate_video_request(request, error);
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    if (illucet_progress(job, "video-transcode", 0.0)) {
        return illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
    }
    IllucetInput input;
    memset(&input, 0, sizeof(input));
    IllucetPartialOutput partial;
    memset(&partial, 0, sizeof(partial));
    AVFormatContext *output = NULL;
    AVCodecContext *decoder = NULL;
    AVCodecContext *encoder = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL;
    IllucetVideoTranscode transcode;
    memset(&transcode, 0, sizeof(transcode));
    status = illucet_open_input(
        input_path,
        job,
        &input,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    if (input.format == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            "Input opened without a format context"
        );
        goto cleanup;
    }
    int video_index = av_find_best_stream(
        input.format,
        AVMEDIA_TYPE_VIDEO,
        -1,
        -1,
        NULL,
        0
    );
    int audio_index = av_find_best_stream(
        input.format,
        AVMEDIA_TYPE_AUDIO,
        -1,
        -1,
        NULL,
        0
    );
    if (video_index < 0) {
        status = illucet_error(
            ILLUCET_FFMPEG_INPUT_ERROR,
            error,
            "Input has no video stream"
        );
        goto cleanup;
    }
    AVStream *input_video = input.format->streams[video_index];
    AVStream *input_audio = audio_index >= 0
        ? input.format->streams[audio_index]
        : NULL;
    if (request->copy_audio
        && input_audio != NULL
        && !illucet_video_container_supports_audio(
            request->container,
            input_audio->codecpar->codec_id
        )) {
        status = illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "The source audio codec cannot be copied into the requested video container"
        );
        goto cleanup;
    }
    const AVCodec *decoder_codec = avcodec_find_decoder(
        input_video->codecpar->codec_id
    );
    if (decoder_codec == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            "Input video decoder is unavailable"
        );
        goto cleanup;
    }
    decoder = avcodec_alloc_context3(decoder_codec);
    if (decoder == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate video decoder"
        );
        goto cleanup;
    }
    int result = avcodec_parameters_to_context(decoder, input_video->codecpar);
    if (result >= 0) {
        decoder->pkt_timebase = input_video->time_base;
        result = avcodec_open2(decoder, decoder_codec, NULL);
    }
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            result,
            "Cannot open input video decoder"
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
    bool source_is_hdr = illucet_video_source_is_hdr(decoder);
    if (
        source_is_hdr
        && request->dynamic_range == ILLUCET_DYNAMIC_RANGE_PRESERVE
        && request->codec != ILLUCET_VIDEO_CODEC_HEVC
    ) {
        status = illucet_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            "Preserving HDR requires HEVC in this native build"
        );
        goto cleanup;
    }
    AVRational frame_rate = request->frame_rate_numerator > 0
        ? (AVRational){
            request->frame_rate_numerator,
            request->frame_rate_denominator
        }
        : av_guess_frame_rate(input.format, input_video, NULL);
    result = illucet_configure_video_encoder(
        output,
        decoder,
        frame_rate,
        request,
        &encoder,
        report
    );
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            result,
            "The requested video encoder cannot open"
        );
        goto cleanup;
    }
    AVStream *output_video = avformat_new_stream(output, NULL);
    if (output_video == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate compatible video stream"
        );
        goto cleanup;
    }
    output_video->time_base = encoder->time_base;
    output_video->avg_frame_rate = encoder->framerate;
    result = avcodec_parameters_from_context(output_video->codecpar, encoder);
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot configure compatible video stream"
        );
        goto cleanup;
    }
    AVStream *output_audio = NULL;
    if (request->copy_audio && input_audio != NULL) {
        output_audio = avformat_new_stream(output, NULL);
        if (output_audio == NULL) {
            status = illucet_error(
                ILLUCET_FFMPEG_OUT_OF_MEMORY,
                error,
                "Cannot allocate copied audio stream"
            );
            goto cleanup;
        }
        result = avcodec_parameters_copy(
            output_audio->codecpar,
            input_audio->codecpar
        );
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot configure copied audio stream"
            );
            goto cleanup;
        }
        output_audio->codecpar->codec_tag = 0;
        output_audio->time_base = input_audio->time_base;
    }
    char encoder_metadata[128];
    snprintf(
        encoder_metadata,
        sizeof(encoder_metadata),
        "Illucet %s",
        report != NULL && report->encoder_name[0] != '\0'
            ? report->encoder_name
            : (request->codec == ILLUCET_VIDEO_CODEC_HEVC
                ? "hevc"
                : "h264")
    );
    illucet_apply_metadata(
        output,
        input.format,
        &request->metadata,
        request->container,
        encoder_metadata
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
            "Cannot write encoded video header"
        );
        goto cleanup;
    }

    packet = av_packet_alloc();
    frame = av_frame_alloc();
    if (packet == NULL || frame == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate video conversion buffers"
        );
        goto cleanup;
    }
    transcode.decoder = decoder;
    transcode.encoder = encoder;
    transcode.input_stream = input_video;
    transcode.output_stream = output_video;
    transcode.output = output;
    transcode.force_constant_frame_rate =
        request->frame_rate_numerator > 0;
    double duration = illucet_duration_seconds(input.format);
    while (true) {
        result = av_read_frame(input.format, packet);
        if (result == AVERROR_EOF) {
            break;
        }
        if (result < 0) {
            if (illucet_job_cancelled(job)) {
                status = illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
            } else {
                status = illucet_av_error(
                    ILLUCET_FFMPEG_INPUT_ERROR,
                    error,
                    result,
                    "Cannot read conversion input"
                );
            }
            goto cleanup;
        }
        if (packet->stream_index == video_index) {
            result = avcodec_send_packet(decoder, packet);
            av_packet_unref(packet);
            if (result >= 0) {
                result = illucet_video_decoder_drain(
                    &transcode,
                    frame,
                    job,
                    duration
                );
            }
            if (result < 0) {
                if (result == AVERROR_EXIT || illucet_job_cancelled(job)) {
                    status = illucet_error(
                        ILLUCET_FFMPEG_CANCELLED,
                        error,
                        "Cancelled"
                    );
                } else {
                    status = illucet_av_error(
                        ILLUCET_FFMPEG_PROCESSING_ERROR,
                        error,
                        result,
                        "Cannot decode or encode video"
                    );
                }
                goto cleanup;
            }
        } else if (
            request->copy_audio
            && audio_index >= 0
            && packet->stream_index == audio_index
        ) {
            if (input_audio == NULL || output_audio == NULL) {
                status = illucet_error(
                    ILLUCET_FFMPEG_PROCESSING_ERROR,
                    error,
                    "Copied audio stream mapping is unexpectedly unavailable"
                );
                av_packet_unref(packet);
                goto cleanup;
            }
            av_packet_rescale_ts(
                packet,
                input_audio->time_base,
                output_audio->time_base
            );
            packet->stream_index = output_audio->index;
            packet->pos = -1;
            result = av_interleaved_write_frame(output, packet);
            av_packet_unref(packet);
            if (result < 0) {
                status = illucet_av_error(
                    ILLUCET_FFMPEG_PROCESSING_ERROR,
                    error,
                    result,
                    "Cannot copy audio packet"
                );
                goto cleanup;
            }
        } else {
            av_packet_unref(packet);
        }
    }
    result = avcodec_send_packet(decoder, NULL);
    if (result >= 0) {
        result = illucet_video_decoder_drain(
            &transcode,
            frame,
            job,
            duration
        );
    }
    if (result >= 0) {
        result = illucet_write_encoded_packets(
            encoder,
            output_video,
            output,
            NULL
        );
    }
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot flush encoded video"
        );
        goto cleanup;
    }
    result = av_write_trailer(output);
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot finalize encoded video"
        );
        goto cleanup;
    }
    illucet_free_output(&output, &partial, false);
    status = illucet_partial_commit(&partial, error);
    if (status == ILLUCET_FFMPEG_OK) {
        illucet_progress(job, "video-transcode", 1.0);
    }

cleanup:
    sws_freeContext(transcode.scaler);
    av_packet_free(&packet);
    av_frame_free(&frame);
    avcodec_free_context(&encoder);
    avcodec_free_context(&decoder);
    if (output != NULL) {
        illucet_free_output(&output, &partial, true);
    }
    illucet_close_input(&input);
    return status;
}

IllucetFFmpegStatus illucet_ffmpeg_transcode_compatible_mp4(
    const char *input_path,
    const char *output_path,
    IllucetFFmpegJob *job,
    char **error
) {
    IllucetVideoTranscodeRequest request;
    memset(&request, 0, sizeof(request));
    request.codec = ILLUCET_VIDEO_CODEC_H264;
    request.container = ILLUCET_MEDIA_CONTAINER_MP4;
    request.bitrate_bits_per_second = 1200000;
    request.dynamic_range = ILLUCET_DYNAMIC_RANGE_PRESERVE;
    request.acceleration = ILLUCET_HARDWARE_ACCELERATION_AUTOMATIC;
    request.copy_audio = true;
    request.fast_start = true;
    request.metadata.preserve_source_metadata = true;
    IllucetVideoTranscodeReport report;
    memset(&report, 0, sizeof(report));
    return illucet_ffmpeg_transcode_video(
        input_path,
        output_path,
        &request,
        &report,
        job,
        error
    );
}
