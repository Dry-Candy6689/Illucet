#include "IllucetFFmpegBridgeInternal.h"

#define ILLUCET_MAX_CHAPTERS 512
#define ILLUCET_MAX_CHAPTER_TITLE_BYTES 1024

static void illucet_free_chapters(AVFormatContext *output) {
    if (output == NULL || output->chapters == NULL) {
        return;
    }
    for (unsigned int index = 0; index < output->nb_chapters; index++) {
        if (output->chapters[index] != NULL) {
            av_dict_free(&output->chapters[index]->metadata);
            av_free(output->chapters[index]);
        }
    }
    av_freep(&output->chapters);
    output->nb_chapters = 0;
}

static int illucet_add_chapter(
    AVFormatContext *output,
    size_t index,
    const char *title,
    double start_seconds,
    double end_seconds
) {
    AVChapter *chapter = av_mallocz(sizeof(*chapter));
    if (chapter == NULL) {
        return AVERROR(ENOMEM);
    }
    chapter->id = (int)index;
    chapter->time_base = (AVRational){1, 1000};
    chapter->start = llrint(start_seconds * 1000.0);
    chapter->end = llrint(end_seconds * 1000.0);
    if (av_dict_set(&chapter->metadata, "title", title, 0) < 0) {
        av_dict_free(&chapter->metadata);
        av_free(chapter);
        return AVERROR(ENOMEM);
    }
    output->chapters[index] = chapter;
    return 0;
}

static int illucet_copy_source_chapter(
    AVFormatContext *output,
    const AVChapter *source,
    size_t index
) {
    const AVDictionaryEntry *entry = av_dict_get(
        source->metadata,
        "title",
        NULL,
        0
    );
    const char *title = entry != NULL ? entry->value : "Chapter";
    double start = source->start * av_q2d(source->time_base);
    double end = source->end * av_q2d(source->time_base);
    if (
        title == NULL
        || strnlen(title, ILLUCET_MAX_CHAPTER_TITLE_BYTES + 1)
            > ILLUCET_MAX_CHAPTER_TITLE_BYTES
        || !isfinite(start)
        || !isfinite(end)
        || start < 0.0
        || end <= start
    ) {
        return AVERROR_INVALIDDATA;
    }
    return illucet_add_chapter(
        output,
        index,
        title,
        start,
        end
    );
}

IllucetFFmpegStatus illucet_ffmpeg_write_chapters(
    const char *media_input,
    const char *output_path,
    const IllucetChapterMuxRequest *request,
    IllucetFFmpegJob *job,
    char **error
) {
    illucet_clear_error(error);
    if (
        !illucet_path_is_valid(media_input)
        || !illucet_path_is_valid(output_path)
        || request == NULL
        || request->chapter_count > ILLUCET_MAX_CHAPTERS
        || (request->chapter_count > 0 && request->chapters == NULL)
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Invalid bounded chapter request"
        );
    }
    for (size_t index = 0; index < request->chapter_count; index++) {
        const IllucetChapter *chapter = &request->chapters[index];
        if (
            chapter->title == NULL
            || chapter->title[0] == '\0'
            || strnlen(chapter->title, ILLUCET_MAX_CHAPTER_TITLE_BYTES + 1)
                > ILLUCET_MAX_CHAPTER_TITLE_BYTES
            || !isfinite(chapter->start_seconds)
            || !isfinite(chapter->end_seconds)
            || chapter->start_seconds < 0.0
            || chapter->end_seconds <= chapter->start_seconds
            || (
                index > 0
                && chapter->start_seconds
                    < request->chapters[index - 1].end_seconds
            )
        ) {
            return illucet_error(
                ILLUCET_FFMPEG_INVALID_ARGUMENT,
                error,
                "Invalid chapter at index %zu",
                index
            );
        }
    }
    if (illucet_progress(job, "chapters", 0.0)) {
        return illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
    }

    IllucetInput input;
    IllucetPartialOutput partial;
    AVFormatContext *output = NULL;
    AVPacket *packet = NULL;
    memset(&input, 0, sizeof(input));
    memset(&partial, 0, sizeof(partial));
    IllucetFFmpegStatus status = illucet_open_input(
        media_input,
        job,
        &input,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    const char *format_name = illucet_container_format_name(request->container);
    if (format_name == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Unsupported chapter output container"
        );
        goto cleanup;
    }
    status = illucet_alloc_output(
        output_path,
        format_name,
        &partial,
        &output,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }
    for (unsigned int index = 0; index < input.format->nb_streams; index++) {
        AVStream *source = input.format->streams[index];
        AVStream *destination = avformat_new_stream(output, NULL);
        if (destination == NULL) {
            status = illucet_error(
                ILLUCET_FFMPEG_OUT_OF_MEMORY,
                error,
                "Cannot allocate chapter output stream"
            );
            goto cleanup;
        }
        int result = avcodec_parameters_copy(
            destination->codecpar,
            source->codecpar
        );
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot copy chapter output stream"
            );
            goto cleanup;
        }
        destination->codecpar->codec_tag = 0;
        destination->time_base = source->time_base;
        destination->disposition = source->disposition;
        av_dict_copy(&destination->metadata, source->metadata, 0);
    }
    illucet_apply_metadata(
        output,
        input.format,
        &request->metadata,
        request->container,
        "Illucet chapter mux"
    );

    size_t chapter_count = request->chapter_count;
    if (chapter_count == 0 && request->preserve_source_chapters) {
        chapter_count = input.format->nb_chapters;
    }
    if (chapter_count > ILLUCET_MAX_CHAPTERS) {
        status = illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Source chapter count exceeds the supported bound"
        );
        goto cleanup;
    }
    if (chapter_count > 0) {
        output->chapters = av_calloc(
            chapter_count,
            sizeof(*output->chapters)
        );
        if (output->chapters == NULL) {
            status = illucet_error(
                ILLUCET_FFMPEG_OUT_OF_MEMORY,
                error,
                "Cannot allocate chapter table"
            );
            goto cleanup;
        }
        output->nb_chapters = (unsigned int)chapter_count;
        for (size_t index = 0; index < chapter_count; index++) {
            int result;
            if (request->chapter_count > 0) {
                const IllucetChapter *chapter = &request->chapters[index];
                result = illucet_add_chapter(
                    output,
                    index,
                    chapter->title,
                    chapter->start_seconds,
                    chapter->end_seconds
                );
            } else {
                result = illucet_copy_source_chapter(
                    output,
                    input.format->chapters[index],
                    index
                );
            }
            if (result < 0) {
                status = illucet_av_error(
                    ILLUCET_FFMPEG_OUT_OF_MEMORY,
                    error,
                    result,
                    "Cannot create chapter"
                );
                goto cleanup;
            }
        }
    }
    int result = illucet_write_output_header(
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
            "Cannot write chapter output header"
        );
        goto cleanup;
    }
    packet = av_packet_alloc();
    if (packet == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate chapter packet"
        );
        goto cleanup;
    }
    double duration = illucet_duration_seconds(input.format);
    while ((result = av_read_frame(input.format, packet)) >= 0) {
        if (illucet_job_cancelled(job)) {
            status = illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
            goto cleanup;
        }
        AVStream *source = input.format->streams[packet->stream_index];
        AVStream *destination = output->streams[packet->stream_index];
        int64_t timestamp = illucet_packet_timestamp(packet);
        AVRational time_base = source->time_base;
        av_packet_rescale_ts(packet, source->time_base, destination->time_base);
        packet->pos = -1;
        result = av_interleaved_write_frame(output, packet);
        av_packet_unref(packet);
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot write chapter media packet"
            );
            goto cleanup;
        }
        double progress = duration > 0.0
            ? timestamp * av_q2d(time_base) / duration
            : -1.0;
        if (illucet_progress(job, "chapters", progress)) {
            status = illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
            goto cleanup;
        }
    }
    if (result != AVERROR_EOF) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot fully read chapter input"
        );
        goto cleanup;
    }
    result = av_write_trailer(output);
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot write chapter output trailer"
        );
        goto cleanup;
    }
    if (output->pb != NULL) {
        avio_closep(&output->pb);
    }
    status = illucet_partial_commit(&partial, error);
    if (status == ILLUCET_FFMPEG_OK) {
        illucet_progress(job, "chapters", 1.0);
    }

cleanup:
    av_packet_free(&packet);
    if (output != NULL) {
        illucet_free_chapters(output);
    }
    illucet_free_output(&output, &partial, status != ILLUCET_FFMPEG_OK);
    illucet_close_input(&input);
    return status;
}
