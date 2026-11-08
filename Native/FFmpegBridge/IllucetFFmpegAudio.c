#include "IllucetFFmpegBridgeInternal.h"

typedef struct IllucetAudioTranscode {
    SwrContext *resampler;
    AVAudioFifo *fifo;
    AVFilterGraph *filter_graph;
    AVFilterContext *filter_source;
    AVFilterContext *filter_sink;
    AVFrame *filtered_frame;
    AVCodecContext *encoder;
    AVStream *output_stream;
    AVFormatContext *output;
    int64_t samples_encoded;
    int input_sample_rate;
} IllucetAudioTranscode;

static int illucet_audio_fifo_encode(
    IllucetAudioTranscode *transcode,
    int sample_count
) {
    AVFrame *frame = av_frame_alloc();
    if (frame == NULL) {
        return AVERROR(ENOMEM);
    }
    frame->nb_samples = sample_count;
    frame->format = transcode->encoder->sample_fmt;
    frame->sample_rate = transcode->encoder->sample_rate;
    frame->pts = transcode->samples_encoded;
    int result = av_channel_layout_copy(
        &frame->ch_layout,
        &transcode->encoder->ch_layout
    );
    if (result >= 0) {
        result = av_frame_get_buffer(frame, 0);
    }
    if (result >= 0) {
        int read = av_audio_fifo_read(
            transcode->fifo,
            (void **)frame->extended_data,
            sample_count
        );
        if (read != sample_count) {
            result = read < 0 ? read : AVERROR_INVALIDDATA;
        }
    }
    if (result >= 0) {
        result = illucet_write_encoded_packets(
            transcode->encoder,
            transcode->output_stream,
            transcode->output,
            frame
        );
    }
    if (result >= 0) {
        transcode->samples_encoded += sample_count;
    }
    av_frame_free(&frame);
    return result;
}

static int illucet_audio_fifo_drain_ready(
    IllucetAudioTranscode *transcode,
    bool final
) {
    int frame_size = transcode->encoder->frame_size > 0
        ? transcode->encoder->frame_size
        : 1152;
    while (
        av_audio_fifo_size(transcode->fifo) >= frame_size
        || (final && av_audio_fifo_size(transcode->fifo) > 0)
    ) {
        int count = av_audio_fifo_size(transcode->fifo);
        if (count > frame_size) {
            count = frame_size;
        }
        int result = illucet_audio_fifo_encode(transcode, count);
        if (result < 0) {
            return result;
        }
    }
    return 0;
}

static int illucet_audio_convert_frame(
    IllucetAudioTranscode *transcode,
    const AVFrame *input_frame
) {
    int input_samples = input_frame != NULL ? input_frame->nb_samples : 0;
    int output_capacity = (int)av_rescale_rnd(
        swr_get_delay(
            transcode->resampler,
            transcode->input_sample_rate
        ) + input_samples,
        transcode->encoder->sample_rate,
        transcode->input_sample_rate,
        AV_ROUND_UP
    );
    if (output_capacity < 1) {
        output_capacity = transcode->encoder->frame_size > 0
            ? transcode->encoder->frame_size
            : 1152;
    }
    uint8_t **converted = NULL;
    int line_size = 0;
    int result = av_samples_alloc_array_and_samples(
        &converted,
        &line_size,
        transcode->encoder->ch_layout.nb_channels,
        output_capacity,
        transcode->encoder->sample_fmt,
        0
    );
    if (result < 0) {
        return result;
    }
    const uint8_t **source = input_frame != NULL
        ? (const uint8_t **)input_frame->extended_data
        : NULL;
    int converted_count = swr_convert(
        transcode->resampler,
        converted,
        output_capacity,
        source,
        input_samples
    );
    if (converted_count < 0) {
        result = converted_count;
        goto cleanup;
    }
    if (converted_count > 0) {
        result = av_audio_fifo_realloc(
            transcode->fifo,
            av_audio_fifo_size(transcode->fifo) + converted_count
        );
        if (result < 0) {
            goto cleanup;
        }
        int written = av_audio_fifo_write(
            transcode->fifo,
            (void **)converted,
            converted_count
        );
        if (written != converted_count) {
            result = written < 0 ? written : AVERROR(ENOMEM);
            goto cleanup;
        }
    }
    result = converted_count;

cleanup:
    if (converted != NULL) {
        av_freep(&converted[0]);
    }
    av_freep(&converted);
    return result;
}

static int illucet_audio_filter_initialize(
    IllucetAudioTranscode *transcode,
    const AVCodecContext *decoder,
    const AVStream *input_stream,
    const IllucetAudioTranscodeRequest *request
) {
    if (!request->normalize_loudness) {
        return 0;
    }
    const AVFilter *source_filter = avfilter_get_by_name("abuffer");
    const AVFilter *loudness_filter = avfilter_get_by_name("loudnorm");
    const AVFilter *format_filter = avfilter_get_by_name("aformat");
    const AVFilter *sink_filter = avfilter_get_by_name("abuffersink");
    if (
        source_filter == NULL
        || loudness_filter == NULL
        || format_filter == NULL
        || sink_filter == NULL
    ) {
        return AVERROR_FILTER_NOT_FOUND;
    }
    transcode->filter_graph = avfilter_graph_alloc();
    if (transcode->filter_graph == NULL) {
        return AVERROR(ENOMEM);
    }

    AVChannelLayout layout;
    memset(&layout, 0, sizeof(layout));
    int result;
    if (decoder->ch_layout.nb_channels > 0) {
        result = av_channel_layout_copy(&layout, &decoder->ch_layout);
    } else {
        av_channel_layout_default(&layout, 2);
        result = 0;
    }
    if (result < 0) {
        av_channel_layout_uninit(&layout);
        return result;
    }
    char layout_description[128] = {0};
    result = av_channel_layout_describe(
        &layout,
        layout_description,
        sizeof(layout_description)
    );
    av_channel_layout_uninit(&layout);
    if (result < 0) {
        return result;
    }

    AVRational time_base = input_stream->time_base;
    if (time_base.num <= 0 || time_base.den <= 0) {
        time_base = (AVRational){1, decoder->sample_rate};
    }
    char source_arguments[512];
    snprintf(
        source_arguments,
        sizeof(source_arguments),
        "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
        time_base.num,
        time_base.den,
        decoder->sample_rate,
        av_get_sample_fmt_name(decoder->sample_fmt),
        layout_description
    );
    result = avfilter_graph_create_filter(
        &transcode->filter_source,
        source_filter,
        "audio_input",
        source_arguments,
        NULL,
        transcode->filter_graph
    );
    if (result < 0) {
        return result;
    }

    char loudness_arguments[256];
    snprintf(
        loudness_arguments,
        sizeof(loudness_arguments),
        "I=%.2f:LRA=%.2f:TP=%.2f:print_format=none",
        request->integrated_loudness_lufs,
        request->loudness_range_lu,
        request->true_peak_dbtp
    );
    AVFilterContext *loudness = NULL;
    result = avfilter_graph_create_filter(
        &loudness,
        loudness_filter,
        "loudness_normalization",
        loudness_arguments,
        NULL,
        transcode->filter_graph
    );
    if (result < 0) {
        return result;
    }

    char format_arguments[512];
    snprintf(
        format_arguments,
        sizeof(format_arguments),
        "sample_fmts=%s:sample_rates=%d:channel_layouts=%s",
        av_get_sample_fmt_name(decoder->sample_fmt),
        decoder->sample_rate,
        layout_description
    );
    AVFilterContext *format = NULL;
    result = avfilter_graph_create_filter(
        &format,
        format_filter,
        "normalization_output_format",
        format_arguments,
        NULL,
        transcode->filter_graph
    );
    if (result < 0) {
        return result;
    }
    result = avfilter_graph_create_filter(
        &transcode->filter_sink,
        sink_filter,
        "audio_output",
        NULL,
        NULL,
        transcode->filter_graph
    );
    if (result >= 0) {
        result = avfilter_link(transcode->filter_source, 0, loudness, 0);
    }
    if (result >= 0) {
        result = avfilter_link(loudness, 0, format, 0);
    }
    if (result >= 0) {
        result = avfilter_link(format, 0, transcode->filter_sink, 0);
    }
    if (result >= 0) {
        result = avfilter_graph_config(transcode->filter_graph, NULL);
    }
    if (result >= 0) {
        transcode->filtered_frame = av_frame_alloc();
        if (transcode->filtered_frame == NULL) {
            result = AVERROR(ENOMEM);
        }
    }
    return result;
}

static int illucet_audio_filter_drain(
    IllucetAudioTranscode *transcode,
    bool final
) {
    while (true) {
        int result = av_buffersink_get_frame(
            transcode->filter_sink,
            transcode->filtered_frame
        );
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
            return 0;
        }
        if (result < 0) {
            return result;
        }
        result = illucet_audio_convert_frame(
            transcode,
            transcode->filtered_frame
        );
        av_frame_unref(transcode->filtered_frame);
        if (result >= 0) {
            result = illucet_audio_fifo_drain_ready(transcode, final);
        }
        if (result < 0) {
            return result;
        }
    }
}

static int illucet_audio_process_frame(
    IllucetAudioTranscode *transcode,
    AVFrame *frame
) {
    if (transcode->filter_graph == NULL) {
        int result = illucet_audio_convert_frame(transcode, frame);
        return result >= 0
            ? illucet_audio_fifo_drain_ready(transcode, false)
            : result;
    }
    int result = av_buffersrc_add_frame_flags(
        transcode->filter_source,
        frame,
        AV_BUFFERSRC_FLAG_KEEP_REF
    );
    return result >= 0
        ? illucet_audio_filter_drain(transcode, false)
        : result;
}

static int illucet_pick_sample_rate(const AVCodec *codec, int preferred) {
    const void *configurations = NULL;
    int count = 0;
    int result = avcodec_get_supported_config(
        NULL,
        codec,
        AV_CODEC_CONFIG_SAMPLE_RATE,
        0,
        &configurations,
        &count
    );
    if (result < 0 || configurations == NULL || count <= 0) {
        return preferred;
    }
    const int *rates = configurations;
    int best = rates[0];
    int best_distance = abs(best - preferred);
    for (int index = 0; index < count; index++) {
        if (rates[index] == preferred) {
            return preferred;
        }
        int distance = abs(rates[index] - preferred);
        if (distance < best_distance) {
            best = rates[index];
            best_distance = distance;
        }
    }
    return best;
}

static const char *illucet_audio_encoder_name(IllucetAudioCodec codec) {
    switch (codec) {
        case ILLUCET_AUDIO_CODEC_AAC:
            return "aac";
        case ILLUCET_AUDIO_CODEC_MP3:
            return "libmp3lame";
        case ILLUCET_AUDIO_CODEC_FLAC:
            return "flac";
        case ILLUCET_AUDIO_CODEC_ALAC:
            return "alac";
        case ILLUCET_AUDIO_CODEC_OPUS:
            return "opus";
        case ILLUCET_AUDIO_CODEC_VORBIS:
            return "vorbis";
        case ILLUCET_AUDIO_CODEC_PCM_S16LE:
            return "pcm_s16le";
    }
    return NULL;
}

static const char *illucet_audio_stage(IllucetAudioCodec codec) {
    switch (codec) {
        case ILLUCET_AUDIO_CODEC_AAC:
            return "audio-aac";
        case ILLUCET_AUDIO_CODEC_MP3:
            return "audio-mp3";
        case ILLUCET_AUDIO_CODEC_FLAC:
            return "audio-flac";
        case ILLUCET_AUDIO_CODEC_ALAC:
            return "audio-alac";
        case ILLUCET_AUDIO_CODEC_OPUS:
            return "audio-opus";
        case ILLUCET_AUDIO_CODEC_VORBIS:
            return "audio-vorbis";
        case ILLUCET_AUDIO_CODEC_PCM_S16LE:
            return "audio-pcm";
    }
    return "audio";
}

static bool illucet_audio_container_is_valid(
    IllucetAudioCodec codec,
    IllucetMediaContainer container
) {
    switch (codec) {
        case ILLUCET_AUDIO_CODEC_AAC:
        case ILLUCET_AUDIO_CODEC_ALAC:
            return container == ILLUCET_MEDIA_CONTAINER_M4A
                || container == ILLUCET_MEDIA_CONTAINER_MOV
                || container == ILLUCET_MEDIA_CONTAINER_MP4
                || container == ILLUCET_MEDIA_CONTAINER_MATROSKA;
        case ILLUCET_AUDIO_CODEC_MP3:
            return container == ILLUCET_MEDIA_CONTAINER_MP3
                || container == ILLUCET_MEDIA_CONTAINER_MATROSKA;
        case ILLUCET_AUDIO_CODEC_FLAC:
            return container == ILLUCET_MEDIA_CONTAINER_FLAC
                || container == ILLUCET_MEDIA_CONTAINER_MATROSKA
                || container == ILLUCET_MEDIA_CONTAINER_OGG;
        case ILLUCET_AUDIO_CODEC_OPUS:
        case ILLUCET_AUDIO_CODEC_VORBIS:
            return container == ILLUCET_MEDIA_CONTAINER_OGG
                || container == ILLUCET_MEDIA_CONTAINER_WEBM
                || container == ILLUCET_MEDIA_CONTAINER_MATROSKA;
        case ILLUCET_AUDIO_CODEC_PCM_S16LE:
            return container == ILLUCET_MEDIA_CONTAINER_WAV
                || container == ILLUCET_MEDIA_CONTAINER_MOV;
    }
    return false;
}

static bool illucet_audio_codec_is_lossless(IllucetAudioCodec codec) {
    return codec == ILLUCET_AUDIO_CODEC_FLAC
        || codec == ILLUCET_AUDIO_CODEC_ALAC
        || codec == ILLUCET_AUDIO_CODEC_PCM_S16LE;
}

static bool illucet_audio_codec_supports_quality(IllucetAudioCodec codec) {
    return codec == ILLUCET_AUDIO_CODEC_AAC
        || codec == ILLUCET_AUDIO_CODEC_MP3
        || codec == ILLUCET_AUDIO_CODEC_VORBIS;
}

static IllucetFFmpegStatus illucet_validate_audio_request(
    const IllucetAudioTranscodeRequest *request,
    char **error
) {
    if (
        request == NULL
        || illucet_audio_encoder_name(request->codec) == NULL
        || illucet_container_format_name(request->container) == NULL
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "A typed audio codec and container are required"
        );
    }
    if (!illucet_audio_container_is_valid(request->codec, request->container)) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "The requested audio codec/container combination is unavailable"
        );
    }
    if (request->sample_rate != 0
        && (request->sample_rate < 8000 || request->sample_rate > 192000)) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Audio sample rate must be preserved or between 8,000 and 192,000 Hz"
        );
    }
    if (
        request->channels != 0
        && request->channels != 1
        && request->channels != 2
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Audio channels must be preserved, mono, or stereo"
        );
    }
    bool lossless = illucet_audio_codec_is_lossless(request->codec);
    if (lossless && request->rate_control != ILLUCET_AUDIO_RATE_CONTROL_LOSSLESS) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Lossless codecs do not accept bitrate or quality controls"
        );
    }
    if (
        request->codec == ILLUCET_AUDIO_CODEC_VORBIS
        && request->rate_control == ILLUCET_AUDIO_RATE_CONTROL_BITRATE
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "The pinned Vorbis encoder supports verified quality control only"
        );
    }
    if (
        !lossless
        && request->rate_control == ILLUCET_AUDIO_RATE_CONTROL_BITRATE
        && (request->bitrate_bits_per_second < 6000
            || request->bitrate_bits_per_second > 512000)
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Audio bitrate must be between 6,000 and 512,000 bits per second"
        );
    }
    if (
        request->rate_control == ILLUCET_AUDIO_RATE_CONTROL_QUALITY
        && (
            !illucet_audio_codec_supports_quality(request->codec)
            || request->quality < 0
            || request->quality > 100
        )
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "The requested codec does not support this quality control"
        );
    }
    if (
        request->normalize_loudness
        && (
            !isfinite(request->integrated_loudness_lufs)
            || request->integrated_loudness_lufs < -70.0
            || request->integrated_loudness_lufs > -5.0
            || !isfinite(request->loudness_range_lu)
            || request->loudness_range_lu < 1.0
            || request->loudness_range_lu > 50.0
            || !isfinite(request->true_peak_dbtp)
            || request->true_peak_dbtp < -9.0
            || request->true_peak_dbtp > 0.0
        )
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Loudness-normalization targets are outside safe bounds"
        );
    }
    return ILLUCET_FFMPEG_OK;
}

static void illucet_configure_audio_rate_control(
    AVCodecContext *encoder,
    const IllucetAudioTranscodeRequest *request
) {
    if (request->rate_control == ILLUCET_AUDIO_RATE_CONTROL_BITRATE) {
        encoder->bit_rate = request->bitrate_bits_per_second;
        return;
    }
    if (request->rate_control != ILLUCET_AUDIO_RATE_CONTROL_QUALITY) {
        return;
    }
    double normalized = (double)request->quality / 100.0;
    double codec_quality = normalized;
    if (request->codec == ILLUCET_AUDIO_CODEC_MP3) {
        codec_quality = 9.0 * (1.0 - normalized);
    } else if (request->codec == ILLUCET_AUDIO_CODEC_VORBIS) {
        codec_quality = 10.0 * normalized;
    } else if (request->codec == ILLUCET_AUDIO_CODEC_AAC) {
        codec_quality = fmax(0.1, 2.0 * normalized);
    }
    encoder->flags |= AV_CODEC_FLAG_QSCALE;
    encoder->global_quality = (int)llround(codec_quality * FF_QP2LAMBDA);
}

IllucetFFmpegStatus illucet_ffmpeg_transcode_audio(
    const char *input_path,
    const char *output_path,
    const IllucetAudioTranscodeRequest *request,
    IllucetFFmpegJob *job,
    char **error
) {
    illucet_clear_error(error);
    IllucetFFmpegStatus status = illucet_validate_audio_request(request, error);
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    const char *stage = illucet_audio_stage(request->codec);
    if (illucet_progress(job, stage, 0.0)) {
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
    IllucetAudioTranscode transcode;
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
    int audio_index = av_find_best_stream(
        input.format,
        AVMEDIA_TYPE_AUDIO,
        -1,
        -1,
        NULL,
        0
    );
    if (audio_index < 0) {
        status = illucet_error(
            ILLUCET_FFMPEG_INPUT_ERROR,
            error,
            "Input has no audio stream"
        );
        goto cleanup;
    }
    AVStream *input_stream = input.format->streams[audio_index];
    const AVCodec *decoder_codec = avcodec_find_decoder(
        input_stream->codecpar->codec_id
    );
    if (decoder_codec == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            "Input audio decoder is unavailable"
        );
        goto cleanup;
    }
    decoder = avcodec_alloc_context3(decoder_codec);
    if (decoder == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate audio decoder"
        );
        goto cleanup;
    }
    int result = avcodec_parameters_to_context(decoder, input_stream->codecpar);
    if (result >= 0) {
        decoder->pkt_timebase = input_stream->time_base;
        result = avcodec_open2(decoder, decoder_codec, NULL);
    }
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            result,
            "Cannot open input audio decoder"
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
    const char *encoder_name = illucet_audio_encoder_name(request->codec);
    const AVCodec *encoder_codec = avcodec_find_encoder_by_name(encoder_name);
    if (encoder_codec == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            "Requested native audio encoder is unavailable"
        );
        goto cleanup;
    }
    encoder = avcodec_alloc_context3(encoder_codec);
    AVStream *output_stream = avformat_new_stream(output, NULL);
    if (encoder == NULL || output_stream == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate encoded audio output"
        );
        goto cleanup;
    }
    int requested_sample_rate = request->sample_rate > 0
        ? request->sample_rate
        : (decoder->sample_rate > 0 ? decoder->sample_rate : ILLUCET_AUDIO_RATE);
    encoder->sample_rate = illucet_pick_sample_rate(
        encoder_codec,
        requested_sample_rate
    );
    if (
        request->sample_rate > 0
        && encoder->sample_rate != request->sample_rate
    ) {
        status = illucet_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            "The requested sample rate is unavailable for this encoder"
        );
        goto cleanup;
    }
    encoder->sample_fmt = illucet_pick_sample_format(
        encoder_codec,
        request->codec == ILLUCET_AUDIO_CODEC_PCM_S16LE
            ? AV_SAMPLE_FMT_S16
            : AV_SAMPLE_FMT_FLTP
    );
    encoder->time_base = (AVRational){1, encoder->sample_rate};
    int channels = request->channels > 0
        ? request->channels
        : decoder->ch_layout.nb_channels;
    if (channels <= 0 || channels > 8) {
        status = illucet_error(
            ILLUCET_FFMPEG_INPUT_ERROR,
            error,
            "The source channel layout cannot be preserved safely"
        );
        goto cleanup;
    }
    if (request->channels > 0 || decoder->ch_layout.nb_channels <= 0) {
        av_channel_layout_default(&encoder->ch_layout, channels);
    } else {
        result = av_channel_layout_copy(
            &encoder->ch_layout,
            &decoder->ch_layout
        );
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot preserve the source channel layout"
            );
            goto cleanup;
        }
    }
    illucet_configure_audio_rate_control(encoder, request);
    if (
        request->codec == ILLUCET_AUDIO_CODEC_OPUS
        || request->codec == ILLUCET_AUDIO_CODEC_VORBIS
    ) {
        encoder->strict_std_compliance = FF_COMPLIANCE_EXPERIMENTAL;
    }
    if ((output->oformat->flags & AVFMT_GLOBALHEADER) != 0) {
        encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }
    result = avcodec_open2(encoder, encoder_codec, NULL);
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            result,
            "Cannot open requested native audio encoder"
        );
        goto cleanup;
    }
    output_stream->time_base = encoder->time_base;
    result = avcodec_parameters_from_context(output_stream->codecpar, encoder);
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot configure encoded audio stream"
        );
        goto cleanup;
    }
    char encoder_metadata[128];
    snprintf(
        encoder_metadata,
        sizeof(encoder_metadata),
        "Illucet %s",
        encoder_name
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
            "Cannot write encoded audio header"
        );
        goto cleanup;
    }

    AVChannelLayout input_layout = decoder->ch_layout;
    if (input_layout.nb_channels <= 0) {
        av_channel_layout_default(&input_layout, channels);
    }
    result = swr_alloc_set_opts2(
        &transcode.resampler,
        &encoder->ch_layout,
        encoder->sample_fmt,
        encoder->sample_rate,
        &input_layout,
        decoder->sample_fmt,
        decoder->sample_rate,
        0,
        NULL
    );
    if (result >= 0) {
        result = swr_init(transcode.resampler);
    }
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot initialize audio resampler"
        );
        goto cleanup;
    }
    transcode.fifo = av_audio_fifo_alloc(
        encoder->sample_fmt,
        encoder->ch_layout.nb_channels,
        encoder->frame_size > 0 ? encoder->frame_size * 2 : 4096
    );
    if (transcode.fifo == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate audio FIFO"
        );
        goto cleanup;
    }
    transcode.encoder = encoder;
    transcode.output_stream = output_stream;
    transcode.output = output;
    transcode.input_sample_rate = decoder->sample_rate;
    result = illucet_audio_filter_initialize(
        &transcode,
        decoder,
        input_stream,
        request
    );
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_CODEC_UNAVAILABLE,
            error,
            result,
            "Cannot initialize loudness normalization"
        );
        goto cleanup;
    }

    packet = av_packet_alloc();
    frame = av_frame_alloc();
    if (packet == NULL || frame == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate audio conversion buffers"
        );
        goto cleanup;
    }
    double duration = illucet_duration_seconds(input.format);
    bool input_ended = false;
    while (!input_ended) {
        result = av_read_frame(input.format, packet);
        if (result == AVERROR_EOF) {
            input_ended = true;
            result = avcodec_send_packet(decoder, NULL);
        } else if (result < 0) {
            if (illucet_job_cancelled(job)) {
                status = illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
            } else {
                status = illucet_av_error(
                    ILLUCET_FFMPEG_INPUT_ERROR,
                    error,
                    result,
                    "Cannot read audio input"
                );
            }
            goto cleanup;
        } else if (packet->stream_index == audio_index) {
            result = avcodec_send_packet(decoder, packet);
        } else {
            result = 0;
        }
        av_packet_unref(packet);
        if (result < 0 && result != AVERROR_EOF) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot submit audio packet to decoder"
            );
            goto cleanup;
        }
        while (true) {
            result = avcodec_receive_frame(decoder, frame);
            if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
                break;
            }
            if (result < 0) {
                status = illucet_av_error(
                    ILLUCET_FFMPEG_PROCESSING_ERROR,
                    error,
                    result,
                    "Cannot decode audio frame"
                );
                goto cleanup;
            }
            result = illucet_audio_process_frame(&transcode, frame);
            if (result < 0) {
                status = illucet_av_error(
                    ILLUCET_FFMPEG_PROCESSING_ERROR,
                    error,
                    result,
                    "Cannot resample or encode audio"
                );
                goto cleanup;
            }
            double progress = -1.0;
            if (duration > 0.0 && frame->best_effort_timestamp != AV_NOPTS_VALUE) {
                progress =
                    frame->best_effort_timestamp
                    * av_q2d(input_stream->time_base)
                    / duration;
            }
            av_frame_unref(frame);
            if (illucet_progress(
                job,
                    stage,
                    illucet_intermediate_progress(progress)
                )) {
                status = illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
                goto cleanup;
            }
        }
    }
    if (transcode.filter_graph != NULL) {
        result = av_buffersrc_add_frame_flags(
            transcode.filter_source,
            NULL,
            0
        );
        if (result >= 0) {
            result = illucet_audio_filter_drain(&transcode, false);
        }
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot flush loudness normalization"
            );
            goto cleanup;
        }
    }
    while (true) {
        result = illucet_audio_convert_frame(&transcode, NULL);
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot flush audio resampler"
            );
            goto cleanup;
        }
        if (result == 0) {
            break;
        }
    }
    result = illucet_audio_fifo_drain_ready(&transcode, true);
    if (result >= 0) {
        result = illucet_write_encoded_packets(
            encoder,
            output_stream,
            output,
            NULL
        );
    }
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot finalize audio encoder"
        );
        goto cleanup;
    }
    result = av_write_trailer(output);
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot finalize encoded audio output"
        );
        goto cleanup;
    }
    illucet_free_output(&output, &partial, false);
    status = illucet_partial_commit(&partial, error);
    if (status == ILLUCET_FFMPEG_OK) {
        illucet_progress(job, stage, 1.0);
    }

cleanup:
    av_packet_free(&packet);
    av_frame_free(&frame);
    av_frame_free(&transcode.filtered_frame);
    avfilter_graph_free(&transcode.filter_graph);
    if (transcode.fifo != NULL) {
        av_audio_fifo_free(transcode.fifo);
    }
    swr_free(&transcode.resampler);
    avcodec_free_context(&encoder);
    avcodec_free_context(&decoder);
    if (output != NULL) {
        illucet_free_output(&output, &partial, true);
    }
    illucet_close_input(&input);
    return status;
}

IllucetFFmpegStatus illucet_ffmpeg_transcode_audio_mp3(
    const char *input_path,
    const char *output_path,
    int bitrate_bits_per_second,
    IllucetFFmpegJob *job,
    char **error
) {
    IllucetAudioTranscodeRequest request;
    memset(&request, 0, sizeof(request));
    request.codec = ILLUCET_AUDIO_CODEC_MP3;
    request.container = ILLUCET_MEDIA_CONTAINER_MP3;
    request.rate_control = ILLUCET_AUDIO_RATE_CONTROL_BITRATE;
    request.bitrate_bits_per_second = bitrate_bits_per_second;
    request.metadata.preserve_source_metadata = true;
    return illucet_ffmpeg_transcode_audio(
        input_path,
        output_path,
        &request,
        job,
        error
    );
}
