#include "IllucetFFmpegBridgeInternal.h"

struct IllucetFFmpegJob {
    atomic_bool cancelled;
    IllucetFFmpegProgressCallback callback;
    void *context;
    char progress_stage[64];
    double last_progress;
    double last_callback_progress;
    int64_t last_callback_time_us;
    bool has_progress;
    bool has_callback_progress;
    bool has_emitted_callback;
    bool has_emitted_intermediate;
    bool poll_only;
};

enum {
    ILLUCET_PROGRESS_MINIMUM_INTERVAL_US = 250000
};

static const double ILLUCET_PROGRESS_MEANINGFUL_DELTA = 0.10;


void illucet_clear_error(char **error) {
    if (error != NULL) {
        *error = NULL;
    }
}
IllucetFFmpegStatus illucet_error(
    IllucetFFmpegStatus status,
    char **error,
    const char *format,
    ...
) {
    if (error == NULL) {
        return status;
    }
    va_list arguments;
    va_start(arguments, format);
    char buffer[1024];
    vsnprintf(buffer, sizeof(buffer), format, arguments);
    va_end(arguments);
    *error = av_strdup(buffer);
    return status;
}

IllucetFFmpegStatus illucet_av_error(
    IllucetFFmpegStatus status,
    char **error,
    int av_error,
    const char *operation
) {
    char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(av_error, detail, sizeof(detail));
    return illucet_error(status, error, "%s: %s (%d)", operation, detail, av_error);
}

bool illucet_job_cancelled(IllucetFFmpegJob *job) {
    if (job == NULL) {
        return false;
    }
    return atomic_load_explicit(&job->cancelled, memory_order_relaxed);
}

bool illucet_progress(IllucetFFmpegJob *job, const char *stage, double progress) {
    if (job == NULL) {
        return false;
    }
    if (atomic_load_explicit(&job->cancelled, memory_order_relaxed)) {
        return true;
    }
    if (job->poll_only) {
        if (
            job->callback != NULL
            && job->callback(NULL, -1.0, job->context) != 0
        ) {
            atomic_store_explicit(&job->cancelled, true, memory_order_relaxed);
            return true;
        }
        return atomic_load_explicit(&job->cancelled, memory_order_relaxed);
    }
    if (job->callback != NULL) {
        bool changed_stage =
            !job->has_progress
            || strncmp(job->progress_stage, stage, sizeof(job->progress_stage)) != 0;
        if (changed_stage) {
            av_strlcpy(job->progress_stage, stage, sizeof(job->progress_stage));
            job->has_progress = true;
            job->has_callback_progress = false;
            job->has_emitted_callback = false;
            job->has_emitted_intermediate = false;
            job->last_callback_time_us = 0;
        }
        if (progress >= 0.0 && !changed_stage && job->last_progress >= 0.0) {
            progress = fmax(progress, job->last_progress);
        }
        if (progress >= 0.0) {
            progress = fmax(0.0, progress);
        }
        if (progress > 1.0) {
            progress = 1.0;
        }
        job->last_progress = progress;
        int64_t now = av_gettime_relative();
        bool is_intermediate = progress > 0.0 && progress < 1.0;
        bool first_intermediate =
            is_intermediate && !job->has_emitted_intermediate;
        bool terminal =
            progress >= 1.0
            && (
                !job->has_callback_progress
                || job->last_callback_progress < 1.0
            );
        bool meaningful_jump =
            progress >= 0.0
            && job->has_callback_progress
            && progress - job->last_callback_progress
                >= ILLUCET_PROGRESS_MEANINGFUL_DELTA;
        bool interval_elapsed =
            job->has_emitted_callback
            && now - job->last_callback_time_us
                >= ILLUCET_PROGRESS_MINIMUM_INTERVAL_US;
        bool should_emit =
            changed_stage
            || !job->has_emitted_callback
            || first_intermediate
            || terminal
            || meaningful_jump
            || interval_elapsed;
        if (!should_emit) {
            return atomic_load_explicit(
                &job->cancelled,
                memory_order_relaxed
            );
        }
        job->has_emitted_callback = true;
        job->last_callback_time_us = now;
        if (progress >= 0.0) {
            job->has_callback_progress = true;
            job->last_callback_progress = progress;
        }
        if (is_intermediate) {
            job->has_emitted_intermediate = true;
        }
        if (job->callback(stage, progress, job->context) != 0) {
            atomic_store_explicit(&job->cancelled, true, memory_order_relaxed);
            return true;
        }
    }
    return atomic_load_explicit(&job->cancelled, memory_order_relaxed);
}

double illucet_intermediate_progress(double progress) {
    return progress >= 0.0 ? fmin(progress, 0.999) : -1.0;
}

int illucet_interrupt_callback(void *opaque) {
    IllucetInput *input = opaque;
    return input != NULL && illucet_job_cancelled(input->job);
}

IllucetFFmpegJob *illucet_ffmpeg_job_create(
    IllucetFFmpegProgressCallback progress_callback,
    void *progress_context
) {
    IllucetFFmpegJob *job = av_mallocz(sizeof(*job));
    if (job == NULL) {
        return NULL;
    }
    atomic_init(&job->cancelled, false);
    job->callback = progress_callback;
    job->context = progress_context;
    return job;
}

void illucet_ffmpeg_job_cancel(IllucetFFmpegJob *job) {
    if (job != NULL) {
        atomic_store_explicit(&job->cancelled, true, memory_order_relaxed);
    }
}

bool illucet_ffmpeg_job_is_cancelled(const IllucetFFmpegJob *job) {
    return job != NULL
        && atomic_load_explicit(&job->cancelled, memory_order_relaxed);
}

void illucet_job_set_poll_only(IllucetFFmpegJob *job, bool poll_only) {
    if (job != NULL) {
        job->poll_only = poll_only;
    }
}

void illucet_ffmpeg_job_destroy(IllucetFFmpegJob *job) {
    av_free(job);
}

void illucet_ffmpeg_string_free(char *string) {
    av_free(string);
}

void illucet_json_string(AVBPrint *print, const char *value) {
    av_bprint_chars(print, '"', 1);
    if (value != NULL) {
        const unsigned char *cursor = (const unsigned char *)value;
        while (*cursor != '\0') {
            unsigned char byte = *cursor++;
            switch (byte) {
                case '"':
                    av_bprintf(print, "\\\"");
                    break;
                case '\\':
                    av_bprintf(print, "\\\\");
                    break;
                case '\b':
                    av_bprintf(print, "\\b");
                    break;
                case '\f':
                    av_bprintf(print, "\\f");
                    break;
                case '\n':
                    av_bprintf(print, "\\n");
                    break;
                case '\r':
                    av_bprintf(print, "\\r");
                    break;
                case '\t':
                    av_bprintf(print, "\\t");
                    break;
                default:
                    if (byte < 0x20) {
                        av_bprintf(print, "\\u%04x", byte);
                    } else {
                        av_bprint_chars(print, (char)byte, 1);
                    }
                    break;
            }
        }
    }
    av_bprint_chars(print, '"', 1);
}

bool illucet_path_is_valid(const char *path) {
    return path != NULL && path[0] != '\0' && strlen(path) < PATH_MAX - 64;
}

IllucetFFmpegStatus illucet_partial_begin(
    const char *final_path,
    IllucetPartialOutput *partial,
    char **error
) {
    if (!illucet_path_is_valid(final_path) || partial == NULL) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "A valid output path is required"
        );
    }
    if (access(final_path, F_OK) == 0) {
        return illucet_error(
            ILLUCET_FFMPEG_OUTPUT_EXISTS,
            error,
            "Refusing to overwrite an existing output"
        );
    }
    memset(partial, 0, sizeof(*partial));
    partial->final_path = final_path;
    for (int attempt = 0; attempt < 32; attempt++) {
        uint32_t first = arc4random();
        uint32_t second = arc4random();
        int written = snprintf(
            partial->path,
            sizeof(partial->path),
            "%s.illucet-partial-%08x%08x",
            final_path,
            first,
            second
        );
        if (written < 0 || (size_t)written >= sizeof(partial->path)) {
            return illucet_error(
                ILLUCET_FFMPEG_INVALID_ARGUMENT,
                error,
                "Output path is too long"
            );
        }
        int descriptor = open(
            partial->path,
            O_CREAT | O_EXCL | O_WRONLY,
            S_IRUSR | S_IWUSR
        );
        if (descriptor >= 0) {
            close(descriptor);
            partial->active = true;
            return ILLUCET_FFMPEG_OK;
        }
        if (errno != EEXIST) {
            return illucet_error(
                ILLUCET_FFMPEG_IO_ERROR,
                error,
                "Cannot create unique partial output: %s",
                strerror(errno)
            );
        }
    }
    return illucet_error(
        ILLUCET_FFMPEG_IO_ERROR,
        error,
        "Cannot allocate a unique partial output"
    );
}

void illucet_partial_discard(IllucetPartialOutput *partial) {
    if (partial != NULL && partial->active) {
        unlink(partial->path);
        partial->active = false;
    }
}

IllucetFFmpegStatus illucet_partial_commit(
    IllucetPartialOutput *partial,
    char **error
) {
    if (partial == NULL || !partial->active) {
        return illucet_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            "Partial output state is invalid"
        );
    }
    if (access(partial->final_path, F_OK) == 0) {
        illucet_partial_discard(partial);
        return illucet_error(
            ILLUCET_FFMPEG_OUTPUT_EXISTS,
            error,
            "Output appeared while processing; partial was discarded"
        );
    }
    if (renamex_np(partial->path, partial->final_path, RENAME_EXCL) != 0) {
        int saved_errno = errno;
        illucet_partial_discard(partial);
        if (saved_errno == EEXIST) {
            return illucet_error(
                ILLUCET_FFMPEG_OUTPUT_EXISTS,
                error,
                "Output appeared while processing; partial was discarded"
            );
        }
        return illucet_error(
            ILLUCET_FFMPEG_IO_ERROR,
            error,
            "Cannot atomically publish output: %s",
            strerror(saved_errno)
        );
    }
    partial->active = false;
    return ILLUCET_FFMPEG_OK;
}

IllucetFFmpegStatus illucet_open_input(
    const char *path,
    IllucetFFmpegJob *job,
    IllucetInput *input,
    char **error
) {
    return illucet_open_input_with_limits(
        path,
        job,
        input,
        0,
        0,
        0,
        false,
        error
    );
}

IllucetFFmpegStatus illucet_open_input_with_limits(
    const char *path,
    IllucetFFmpegJob *job,
    IllucetInput *input,
    int64_t probe_size,
    int64_t max_analyze_duration,
    int max_probe_packets,
    bool export_all_metadata,
    char **error
) {
    if (!illucet_path_is_valid(path) || input == NULL) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "A valid input path is required"
        );
    }
    memset(input, 0, sizeof(*input));
    input->job = job;
    input->format = avformat_alloc_context();
    if (input->format == NULL) {
        return illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate an input context"
        );
    }
    input->format->interrupt_callback.callback = illucet_interrupt_callback;
    input->format->interrupt_callback.opaque = input;
    if (probe_size > 0) {
        input->format->probesize = probe_size;
    }
    if (max_analyze_duration > 0) {
        input->format->max_analyze_duration = max_analyze_duration;
    }
    if (max_probe_packets > 0) {
        input->format->max_probe_packets = max_probe_packets;
    }
    AVDictionary *open_options = NULL;
    if (export_all_metadata) {
        int option_result = av_dict_set(
            &open_options,
            "export_all",
            "1",
            0
        );
        if (option_result < 0) {
            avformat_free_context(input->format);
            input->format = NULL;
            return illucet_av_error(
                ILLUCET_FFMPEG_OUT_OF_MEMORY,
                error,
                option_result,
                "Cannot configure complete metadata probing"
            );
        }
    }
    int result = avformat_open_input(
        &input->format,
        path,
        NULL,
        &open_options
    );
    av_dict_free(&open_options);
    if (result < 0) {
        avformat_close_input(&input->format);
        if (illucet_job_cancelled(job)) {
            return illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
        }
        return illucet_av_error(
            ILLUCET_FFMPEG_INPUT_ERROR,
            error,
            result,
            "Cannot open input"
        );
    }
    result = avformat_find_stream_info(input->format, NULL);
    if (result < 0) {
        avformat_close_input(&input->format);
        if (illucet_job_cancelled(job)) {
            return illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
        }
        return illucet_av_error(
            ILLUCET_FFMPEG_INPUT_ERROR,
            error,
            result,
            "Cannot read stream information"
        );
    }
    return ILLUCET_FFMPEG_OK;
}

void illucet_close_input(IllucetInput *input) {
    if (input != NULL) {
        avformat_close_input(&input->format);
    }
}

IllucetFFmpegStatus illucet_alloc_output(
    const char *final_path,
    const char *format_name,
    IllucetPartialOutput *partial,
    AVFormatContext **output,
    char **error
) {
    IllucetFFmpegStatus status = illucet_partial_begin(final_path, partial, error);
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    int result = avformat_alloc_output_context2(
        output,
        NULL,
        format_name,
        final_path
    );
    if (result < 0 || *output == NULL) {
        illucet_partial_discard(partial);
        return illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result < 0 ? result : AVERROR_UNKNOWN,
            "Cannot create output container"
        );
    }
    /*
     * Muxers such as MOV with +faststart reopen AVFormatContext.url while
     * writing the trailer. The final path intentionally does not exist until
     * atomic publication, so the context URL must identify the active partial
     * file rather than the eventual destination.
     */
    av_freep(&(*output)->url);
    (*output)->url = av_strdup(partial->path);
    if ((*output)->url == NULL) {
        avformat_free_context(*output);
        *output = NULL;
        illucet_partial_discard(partial);
        return illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot store the partial output URL"
        );
    }
    if (((*output)->oformat->flags & AVFMT_NOFILE) == 0) {
        result = avio_open(&(*output)->pb, partial->path, AVIO_FLAG_WRITE);
        if (result < 0) {
            avformat_free_context(*output);
            *output = NULL;
            illucet_partial_discard(partial);
            return illucet_av_error(
                ILLUCET_FFMPEG_IO_ERROR,
                error,
                result,
                "Cannot open partial output"
            );
        }
    }
    return ILLUCET_FFMPEG_OK;
}

void illucet_free_output(
    AVFormatContext **output,
    IllucetPartialOutput *partial,
    bool discard
) {
    if (output != NULL && *output != NULL) {
        if (((*output)->oformat->flags & AVFMT_NOFILE) == 0 && (*output)->pb != NULL) {
            avio_closep(&(*output)->pb);
        }
        avformat_free_context(*output);
        *output = NULL;
    }
    if (discard) {
        illucet_partial_discard(partial);
    }
}

double illucet_duration_seconds(const AVFormatContext *format) {
    if (format == NULL || format->duration <= 0) {
        return -1.0;
    }
    return (double)format->duration / AV_TIME_BASE;
}

enum AVSampleFormat illucet_pick_sample_format(
    const AVCodec *codec,
    enum AVSampleFormat preferred
) {
    const void *configurations = NULL;
    int count = 0;
    int result = avcodec_get_supported_config(
        NULL,
        codec,
        AV_CODEC_CONFIG_SAMPLE_FORMAT,
        0,
        &configurations,
        &count
    );
    if (result < 0 || configurations == NULL || count <= 0) {
        return preferred;
    }
    const enum AVSampleFormat *formats = configurations;
    for (int index = 0; index < count; index++) {
        if (formats[index] == preferred) {
            return preferred;
        }
    }
    return formats[0];
}

int64_t illucet_packet_timestamp(const AVPacket *packet) {
    if (packet->dts != AV_NOPTS_VALUE) {
        return packet->dts;
    }
    if (packet->pts != AV_NOPTS_VALUE) {
        return packet->pts;
    }
    return 0;
}

int illucet_write_encoded_packets(
    AVCodecContext *encoder,
    AVStream *stream,
    AVFormatContext *output,
    AVFrame *frame
) {
    int result = avcodec_send_frame(encoder, frame);
    if (result < 0) {
        return result;
    }
    AVPacket *packet = av_packet_alloc();
    if (packet == NULL) {
        return AVERROR(ENOMEM);
    }
    while (true) {
        result = avcodec_receive_packet(encoder, packet);
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
            result = 0;
            break;
        }
        if (result < 0) {
            break;
        }
        av_packet_rescale_ts(packet, encoder->time_base, stream->time_base);
        packet->stream_index = stream->index;
        packet->pos = -1;
        result = av_interleaved_write_frame(output, packet);
        av_packet_unref(packet);
        if (result < 0) {
            break;
        }
    }
    av_packet_free(&packet);
    return result;
}

const char *illucet_container_format_name(IllucetMediaContainer container) {
    switch (container) {
        case ILLUCET_MEDIA_CONTAINER_MP4:
            return "mp4";
        case ILLUCET_MEDIA_CONTAINER_MOV:
            return "mov";
        case ILLUCET_MEDIA_CONTAINER_MATROSKA:
            return "matroska";
        case ILLUCET_MEDIA_CONTAINER_WEBM:
            return "webm";
        case ILLUCET_MEDIA_CONTAINER_M4A:
            return "ipod";
        case ILLUCET_MEDIA_CONTAINER_MP3:
            return "mp3";
        case ILLUCET_MEDIA_CONTAINER_OGG:
            return "ogg";
        case ILLUCET_MEDIA_CONTAINER_FLAC:
            return "flac";
        case ILLUCET_MEDIA_CONTAINER_WAV:
            return "wav";
    }
    return NULL;
}
