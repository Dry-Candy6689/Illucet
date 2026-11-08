#include "IllucetFFmpegBridgeInternal.h"

static enum AVPixelFormat illucet_pick_pixel_format(
    const AVCodec *codec,
    enum AVPixelFormat preferred
) {
    const void *configurations = NULL;
    int count = 0;
    int result = avcodec_get_supported_config(
        NULL,
        codec,
        AV_CODEC_CONFIG_PIX_FORMAT,
        0,
        &configurations,
        &count
    );
    if (result < 0 || configurations == NULL || count <= 0) {
        return preferred;
    }
    const enum AVPixelFormat *formats = configurations;
    for (int index = 0; index < count; index++) {
        if (formats[index] == preferred) {
            return preferred;
        }
    }
    return formats[0];
}

static void illucet_fill_video_frame(AVFrame *frame, int frame_number) {
    int width = frame->width;
    int height = frame->height;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            frame->data[0][y * frame->linesize[0] + x] =
                (uint8_t)((x + y + frame_number * 3) & 255);
        }
    }
    for (int y = 0; y < height / 2; y++) {
        for (int x = 0; x < width / 2; x++) {
            frame->data[1][y * frame->linesize[1] + x] =
                (uint8_t)((96 + frame_number * 2 + x / 3) & 255);
            frame->data[2][y * frame->linesize[2] + x] =
                (uint8_t)((160 - frame_number * 2 + y / 2) & 255);
        }
    }
}

static void illucet_fill_hdr_video_frame(AVFrame *frame, int frame_number) {
    for (int y = 0; y < frame->height; y++) {
        uint16_t *row = (uint16_t *)(frame->data[0]
            + y * frame->linesize[0]);
        for (int x = 0; x < frame->width; x++) {
            int value = 64 + ((x + y + frame_number * 5) % 817);
            row[x] = (uint16_t)(value << 6);
        }
    }
    for (int y = 0; y < frame->height / 2; y++) {
        uint16_t *row = (uint16_t *)(frame->data[1]
            + y * frame->linesize[1]);
        for (int x = 0; x < frame->width; x += 2) {
            row[x] = (uint16_t)((448 + (frame_number % 64)) << 6);
            row[x + 1] = (uint16_t)((576 - (frame_number % 64)) << 6);
        }
    }
}

static void illucet_fill_audio_frame(
    AVFrame *frame,
    int64_t first_sample,
    int sample_rate
) {
    int channels = frame->ch_layout.nb_channels;
    bool planar = av_sample_fmt_is_planar((enum AVSampleFormat)frame->format) != 0;
    enum AVSampleFormat packed = av_get_packed_sample_fmt(
        (enum AVSampleFormat)frame->format
    );
    for (int sample = 0; sample < frame->nb_samples; sample++) {
        double time = (double)(first_sample + sample) / sample_rate;
        double wave = sin(2.0 * M_PI * 440.0 * time) * 0.20;
        for (int channel = 0; channel < channels; channel++) {
            uint8_t *plane = frame->extended_data[planar ? channel : 0];
            int position = planar ? sample : sample * channels + channel;
            switch (packed) {
                case AV_SAMPLE_FMT_FLT:
                    ((float *)plane)[position] = (float)wave;
                    break;
                case AV_SAMPLE_FMT_DBL:
                    ((double *)plane)[position] = wave;
                    break;
                case AV_SAMPLE_FMT_S16:
                    ((int16_t *)plane)[position] =
                        (int16_t)lrint(wave * INT16_MAX);
                    break;
                case AV_SAMPLE_FMT_S32:
                    ((int32_t *)plane)[position] =
                        (int32_t)llrint(wave * INT32_MAX);
                    break;
                case AV_SAMPLE_FMT_U8:
                    plane[position] = (uint8_t)lrint((wave + 1.0) * 127.5);
                    break;
                default:
                    break;
            }
        }
    }
}

static IllucetFFmpegStatus illucet_generate_container_fixture(
    const char *path,
    const char *format_name,
    enum AVCodecID video_codec_id,
    enum AVCodecID audio_codec_id,
    int video_seconds,
    int audio_seconds,
    bool hdr,
    bool fragmented,
    const char *stage,
    IllucetFFmpegJob *job,
    char **error
) {
    if (illucet_progress(job, stage, 0.0)) {
        return illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
    }
    IllucetPartialOutput partial;
    AVFormatContext *output = NULL;
    AVCodecContext *video_encoder = NULL;
    AVCodecContext *audio_encoder = NULL;
    AVStream *video_stream = NULL;
    AVStream *audio_stream = NULL;
    IllucetFFmpegStatus status = illucet_alloc_output(
        path,
        format_name,
        &partial,
        &output,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }

    int result = 0;
    if (video_codec_id != AV_CODEC_ID_NONE) {
        const AVCodec *video_codec = hdr
            ? avcodec_find_encoder_by_name("hevc_videotoolbox")
            : avcodec_find_encoder(video_codec_id);
        if (video_codec == NULL) {
            status = illucet_error(
                ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
                error,
                "Required fixture video encoder is unavailable"
            );
            goto cleanup;
        }
        video_encoder = avcodec_alloc_context3(video_codec);
        video_stream = avformat_new_stream(output, NULL);
        if (video_encoder == NULL || video_stream == NULL) {
            status = illucet_error(
                ILLUCET_FFMPEG_OUT_OF_MEMORY,
                error,
                "Cannot allocate fixture video encoder"
            );
            goto cleanup;
        }
        video_encoder->codec_id = video_codec_id;
        video_encoder->width = ILLUCET_VIDEO_WIDTH;
        video_encoder->height = ILLUCET_VIDEO_HEIGHT;
        video_encoder->time_base = (AVRational){1, ILLUCET_VIDEO_FPS};
        video_encoder->framerate = (AVRational){ILLUCET_VIDEO_FPS, 1};
        video_encoder->pix_fmt = hdr
            ? AV_PIX_FMT_P010LE
            : illucet_pick_pixel_format(
                video_codec,
                AV_PIX_FMT_YUV420P
            );
        video_encoder->bit_rate = 400000;
        video_encoder->gop_size = 12;
        if (hdr) {
            video_encoder->profile = AV_PROFILE_HEVC_MAIN_10;
            video_encoder->color_range = AVCOL_RANGE_MPEG;
            video_encoder->colorspace = AVCOL_SPC_BT2020_NCL;
            video_encoder->color_primaries = AVCOL_PRI_BT2020;
            video_encoder->color_trc = AVCOL_TRC_SMPTE2084;
            av_opt_set(video_encoder->priv_data, "allow_sw", "1", 0);
            av_opt_set(video_encoder->priv_data, "realtime", "1", 0);
        }
        if ((output->oformat->flags & AVFMT_GLOBALHEADER) != 0) {
            video_encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        }
        result = avcodec_open2(video_encoder, video_codec, NULL);
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
                error,
                result,
                "Cannot open fixture video encoder"
            );
            goto cleanup;
        }
        video_stream->time_base = video_encoder->time_base;
        result = avcodec_parameters_from_context(
            video_stream->codecpar,
            video_encoder
        );
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot configure fixture video stream"
            );
            goto cleanup;
        }
    }

    if (audio_codec_id != AV_CODEC_ID_NONE) {
        const AVCodec *audio_codec = avcodec_find_encoder(audio_codec_id);
        if (audio_codec == NULL) {
            status = illucet_error(
                ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
                error,
                "Required fixture audio encoder is unavailable"
            );
            goto cleanup;
        }
        audio_encoder = avcodec_alloc_context3(audio_codec);
        audio_stream = avformat_new_stream(output, NULL);
        if (audio_encoder == NULL || audio_stream == NULL) {
            status = illucet_error(
                ILLUCET_FFMPEG_OUT_OF_MEMORY,
                error,
                "Cannot allocate fixture audio encoder"
            );
            goto cleanup;
        }
        audio_encoder->codec_id = audio_codec_id;
        audio_encoder->sample_rate = ILLUCET_AUDIO_RATE;
        audio_encoder->time_base = (AVRational){1, ILLUCET_AUDIO_RATE};
        audio_encoder->sample_fmt = illucet_pick_sample_format(
            audio_codec,
            AV_SAMPLE_FMT_FLTP
        );
        audio_encoder->bit_rate = 128000;
        av_channel_layout_default(&audio_encoder->ch_layout, 2);
        if ((output->oformat->flags & AVFMT_GLOBALHEADER) != 0) {
            audio_encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        }
        result = avcodec_open2(audio_encoder, audio_codec, NULL);
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
                error,
                result,
                "Cannot open fixture audio encoder"
            );
            goto cleanup;
        }
        audio_stream->time_base = audio_encoder->time_base;
        result = avcodec_parameters_from_context(
            audio_stream->codecpar,
            audio_encoder
        );
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot configure fixture audio stream"
            );
            goto cleanup;
        }
    }

    av_dict_set(&output->metadata, "title", "Illucet Stage 0 Fixture", 0);
    av_dict_set(&output->metadata, "artist", "Illucet", 0);
    AVDictionary *header_options = NULL;
    if (fragmented) {
        av_dict_set(
            &header_options,
            "movflags",
            "frag_keyframe+empty_moov+default_base_moof",
            0
        );
    }
    result = avformat_write_header(output, &header_options);
    av_dict_free(&header_options);
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot write fixture header"
        );
        goto cleanup;
    }

    int video_frame_number = 0;
    int64_t audio_sample = 0;
    const int video_frame_count = video_seconds * ILLUCET_VIDEO_FPS;
    const int64_t audio_sample_count =
        (int64_t)audio_seconds * ILLUCET_AUDIO_RATE;
    while (
        (
            video_encoder != NULL
            && video_frame_number < video_frame_count
        )
        || (
            audio_encoder != NULL
            && audio_sample < audio_sample_count
        )
    ) {
        double combined_progress = 0.0;
        int active_streams = 0;
        if (video_encoder != NULL) {
            combined_progress +=
                (double)video_frame_number / video_frame_count;
            active_streams++;
        }
        if (audio_encoder != NULL) {
            combined_progress += (double)audio_sample / audio_sample_count;
            active_streams++;
        }
        if (active_streams > 0) {
            combined_progress /= active_streams;
        }
        if (illucet_progress(job, stage, fmin(combined_progress, 0.999))) {
            status = illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
            goto cleanup;
        }

        bool encode_video = video_encoder != NULL
            && video_frame_number < video_frame_count
            && (
                audio_encoder == NULL
                || audio_sample >= audio_sample_count
                || av_compare_ts(
                    video_frame_number,
                    video_encoder->time_base,
                    audio_sample,
                    audio_encoder->time_base
                ) <= 0
            );
        if (encode_video) {
            AVFrame *frame = av_frame_alloc();
            if (frame == NULL) {
                status = illucet_error(
                    ILLUCET_FFMPEG_OUT_OF_MEMORY,
                    error,
                    "Cannot allocate fixture video frame"
                );
                goto cleanup;
            }
            frame->format = video_encoder->pix_fmt;
            frame->width = video_encoder->width;
            frame->height = video_encoder->height;
            frame->pts = video_frame_number;
            frame->color_range = video_encoder->color_range;
            frame->colorspace = video_encoder->colorspace;
            frame->color_primaries = video_encoder->color_primaries;
            frame->color_trc = video_encoder->color_trc;
            result = av_frame_get_buffer(frame, 32);
            if (result >= 0) {
                result = av_frame_make_writable(frame);
            }
            if (result >= 0) {
                if (hdr) {
                    illucet_fill_hdr_video_frame(frame, video_frame_number);
                } else {
                    illucet_fill_video_frame(frame, video_frame_number);
                }
                result = illucet_write_encoded_packets(
                    video_encoder,
                    video_stream,
                    output,
                    frame
                );
            }
            av_frame_free(&frame);
            if (result < 0) {
                status = illucet_av_error(
                    ILLUCET_FFMPEG_PROCESSING_ERROR,
                    error,
                    result,
                    "Cannot encode fixture video"
                );
                goto cleanup;
            }
            video_frame_number++;
        } else if (audio_encoder != NULL && audio_sample < audio_sample_count) {
            int requested = audio_encoder->frame_size > 0
                ? audio_encoder->frame_size
                : 1024;
            int remaining = (int)(audio_sample_count - audio_sample);
            int sample_count = remaining < requested ? remaining : requested;
            AVFrame *frame = av_frame_alloc();
            if (frame == NULL) {
                status = illucet_error(
                    ILLUCET_FFMPEG_OUT_OF_MEMORY,
                    error,
                    "Cannot allocate fixture audio frame"
                );
                goto cleanup;
            }
            frame->format = audio_encoder->sample_fmt;
            frame->sample_rate = audio_encoder->sample_rate;
            frame->nb_samples = sample_count;
            frame->pts = audio_sample;
            result = av_channel_layout_copy(
                &frame->ch_layout,
                &audio_encoder->ch_layout
            );
            if (result >= 0) {
                result = av_frame_get_buffer(frame, 0);
            }
            if (result >= 0) {
                illucet_fill_audio_frame(
                    frame,
                    audio_sample,
                    audio_encoder->sample_rate
                );
                result = illucet_write_encoded_packets(
                    audio_encoder,
                    audio_stream,
                    output,
                    frame
                );
            }
            av_frame_free(&frame);
            if (result < 0) {
                status = illucet_av_error(
                    ILLUCET_FFMPEG_PROCESSING_ERROR,
                    error,
                    result,
                    "Cannot encode fixture audio"
                );
                goto cleanup;
            }
            audio_sample += sample_count;
        }
    }

    if (video_encoder != NULL) {
        result = illucet_write_encoded_packets(
            video_encoder,
            video_stream,
            output,
            NULL
        );
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot flush fixture video"
            );
            goto cleanup;
        }
    }
    if (audio_encoder != NULL) {
        result = illucet_write_encoded_packets(
            audio_encoder,
            audio_stream,
            output,
            NULL
        );
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot flush fixture audio"
            );
            goto cleanup;
        }
    }
    result = av_write_trailer(output);
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot finalize fixture"
        );
        goto cleanup;
    }
    illucet_free_output(&output, &partial, false);
    status = illucet_partial_commit(&partial, error);
    if (status == ILLUCET_FFMPEG_OK) {
        illucet_progress(job, stage, 1.0);
    }

cleanup:
    avcodec_free_context(&video_encoder);
    avcodec_free_context(&audio_encoder);
    if (output != NULL) {
        illucet_free_output(&output, &partial, true);
    }
    return status;
}

static IllucetFFmpegStatus illucet_generate_artwork_fixture(
    const char *path,
    IllucetFFmpegJob *job,
    char **error
) {
    if (illucet_progress(job, "fixture-artwork", 0.0)) {
        return illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
    }
    IllucetPartialOutput partial;
    IllucetFFmpegStatus status = illucet_partial_begin(path, &partial, error);
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_MJPEG);
    if (codec == NULL) {
        illucet_partial_discard(&partial);
        return illucet_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            "MJPEG encoder is unavailable"
        );
    }
    AVCodecContext *encoder = avcodec_alloc_context3(codec);
    AVFrame *frame = NULL;
    AVPacket *packet = NULL;
    AVIOContext *io = NULL;
    int result = 0;
    if (encoder == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate artwork encoder"
        );
        goto cleanup;
    }
    encoder->width = 300;
    encoder->height = 300;
    encoder->time_base = (AVRational){1, 1};
    encoder->pix_fmt = illucet_pick_pixel_format(codec, AV_PIX_FMT_YUVJ420P);
    result = avcodec_open2(encoder, codec, NULL);
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            result,
            "Cannot open artwork encoder"
        );
        goto cleanup;
    }
    frame = av_frame_alloc();
    packet = av_packet_alloc();
    if (frame == NULL || packet == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate artwork buffers"
        );
        goto cleanup;
    }
    frame->format = encoder->pix_fmt;
    frame->width = encoder->width;
    frame->height = encoder->height;
    frame->pts = 0;
    result = av_frame_get_buffer(frame, 32);
    if (result >= 0) {
        result = av_frame_make_writable(frame);
    }
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot allocate artwork pixels"
        );
        goto cleanup;
    }
    illucet_fill_video_frame(frame, 17);
    result = avcodec_send_frame(encoder, frame);
    if (result >= 0) {
        result = avcodec_receive_packet(encoder, packet);
    }
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot encode artwork"
        );
        goto cleanup;
    }
    if (illucet_progress(job, "fixture-artwork", 0.5)) {
        status = illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
        goto cleanup;
    }
    result = avio_open(&io, partial.path, AVIO_FLAG_WRITE);
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_IO_ERROR,
            error,
            result,
            "Cannot open artwork partial"
        );
        goto cleanup;
    }
    avio_write(io, packet->data, packet->size);
    avio_flush(io);
    result = io->error;
    if (avio_closep(&io) < 0 && result >= 0) {
        result = AVERROR(EIO);
    }
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_IO_ERROR,
            error,
            result,
            "Cannot write artwork"
        );
        goto cleanup;
    }
    status = illucet_partial_commit(&partial, error);
    if (status == ILLUCET_FFMPEG_OK) {
        illucet_progress(job, "fixture-artwork", 1.0);
    }

cleanup:
    if (io != NULL) {
        avio_closep(&io);
    }
    av_packet_free(&packet);
    av_frame_free(&frame);
    avcodec_free_context(&encoder);
    if (status != ILLUCET_FFMPEG_OK) {
        illucet_partial_discard(&partial);
    }
    return status;
}

IllucetFFmpegStatus illucet_ffmpeg_generate_fixtures(
    const char *video_only_mp4,
    const char *audio_only_m4a,
    const char *incompatible_mkv,
    const char *artwork_jpeg,
    IllucetFFmpegJob *job,
    char **error
) {
    illucet_clear_error(error);
    if (
        !illucet_path_is_valid(video_only_mp4)
        || !illucet_path_is_valid(audio_only_m4a)
        || !illucet_path_is_valid(incompatible_mkv)
        || !illucet_path_is_valid(artwork_jpeg)
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "All fixture output paths are required"
        );
    }
    IllucetFFmpegStatus status = illucet_generate_container_fixture(
        video_only_mp4,
        "mp4",
        AV_CODEC_ID_MPEG4,
        AV_CODEC_ID_NONE,
        ILLUCET_FIXTURE_SECONDS,
        ILLUCET_FIXTURE_SECONDS,
        false,
        false,
        "fixture-video",
        job,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    status = illucet_generate_container_fixture(
        audio_only_m4a,
        "ipod",
        AV_CODEC_ID_NONE,
        AV_CODEC_ID_AAC,
        ILLUCET_FIXTURE_SECONDS,
        ILLUCET_FIXTURE_SECONDS,
        false,
        false,
        "fixture-audio",
        job,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    status = illucet_generate_container_fixture(
        incompatible_mkv,
        "matroska",
        AV_CODEC_ID_FFV1,
        AV_CODEC_ID_AAC,
        ILLUCET_FIXTURE_SECONDS,
        ILLUCET_FIXTURE_SECONDS,
        false,
        false,
        "fixture-incompatible",
        job,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    return illucet_generate_artwork_fixture(artwork_jpeg, job, error);
}

IllucetFFmpegStatus illucet_ffmpeg_generate_early_audio_fixture(
    const char *output_path,
    IllucetFFmpegJob *job,
    char **error
) {
    illucet_clear_error(error);
    if (!illucet_path_is_valid(output_path)) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "The early-audio fixture output path is required"
        );
    }
    return illucet_generate_container_fixture(
        output_path,
        "matroska",
        AV_CODEC_ID_FFV1,
        AV_CODEC_ID_AAC,
        ILLUCET_FIXTURE_SECONDS,
        1,
        false,
        false,
        "fixture-early-audio",
        job,
        error
    );
}

IllucetFFmpegStatus illucet_ffmpeg_generate_hdr_fixture(
    const char *output_path,
    IllucetFFmpegJob *job,
    char **error
) {
    illucet_clear_error(error);
    if (!illucet_path_is_valid(output_path)) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "The HDR fixture output path is required"
        );
    }
    return illucet_generate_container_fixture(
        output_path,
        "mp4",
        AV_CODEC_ID_HEVC,
        AV_CODEC_ID_AAC,
        ILLUCET_FIXTURE_SECONDS,
        ILLUCET_FIXTURE_SECONDS,
        true,
        false,
        "fixture-hdr",
        job,
        error
    );
}

IllucetFFmpegStatus illucet_ffmpeg_generate_dash_fixture(
    const char *output_path,
    IllucetFFmpegJob *job,
    char **error
) {
    illucet_clear_error(error);
    if (!illucet_path_is_valid(output_path)) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "The fragmented MP4 fixture output path is required"
        );
    }
    return illucet_generate_container_fixture(
        output_path,
        "mp4",
        AV_CODEC_ID_MPEG4,
        AV_CODEC_ID_NONE,
        ILLUCET_FIXTURE_SECONDS,
        ILLUCET_FIXTURE_SECONDS,
        false,
        true,
        "fixture-dash",
        job,
        error
    );
}
