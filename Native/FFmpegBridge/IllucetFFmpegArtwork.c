#include "IllucetFFmpegBridgeInternal.h"

#define ILLUCET_ARTWORK_MAX_CHAPTERS 512

IllucetFFmpegStatus illucet_ffmpeg_attach_artwork(
    const char *media_path,
    const char *image_path,
    const char *output_path,
    IllucetMediaContainer container,
    bool fast_start,
    const IllucetMediaMetadata *metadata,
    IllucetFFmpegJob *job,
    char **error
) {
    illucet_clear_error(error);
    if (
        container != ILLUCET_MEDIA_CONTAINER_MP3
        && container != ILLUCET_MEDIA_CONTAINER_M4A
        && container != ILLUCET_MEDIA_CONTAINER_MP4
        && container != ILLUCET_MEDIA_CONTAINER_FLAC
    ) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Artwork is unavailable for the requested container"
        );
    }
    if (illucet_progress(job, "artwork", 0.0)) {
        return illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
    }
    IllucetInput media_input;
    IllucetInput artwork_input;
    memset(&media_input, 0, sizeof(media_input));
    memset(&artwork_input, 0, sizeof(artwork_input));
    IllucetPartialOutput partial;
    memset(&partial, 0, sizeof(partial));
    AVFormatContext *output = NULL;
    AVPacket *packet = NULL;
    int stream_map[128];
    for (int i = 0; i < 128; i++) { stream_map[i] = -1; }
    IllucetFFmpegStatus status = illucet_open_input(
        media_path,
        job,
        &media_input,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        return status;
    }
    status = illucet_open_input(image_path, job, &artwork_input, error);
    if (status != ILLUCET_FFMPEG_OK) {
        illucet_close_input(&media_input);
        return status;
    }
    if (media_input.format == NULL || artwork_input.format == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            "Artwork inputs opened without format contexts"
        );
        goto cleanup;
    }
    int audio_index = av_find_best_stream(
        media_input.format,
        AVMEDIA_TYPE_AUDIO,
        -1,
        -1,
        NULL,
        0
    );
    int artwork_index = av_find_best_stream(
        artwork_input.format,
        AVMEDIA_TYPE_VIDEO,
        -1,
        -1,
        NULL,
        0
    );
    enum AVCodecID audio_codec = audio_index >= 0
        ? media_input.format->streams[audio_index]->codecpar->codec_id
        : AV_CODEC_ID_NONE;
    bool compatible_audio =
        (container == ILLUCET_MEDIA_CONTAINER_MP3
            && audio_codec == AV_CODEC_ID_MP3)
        || (
            (
                container == ILLUCET_MEDIA_CONTAINER_M4A
                || container == ILLUCET_MEDIA_CONTAINER_MP4
            )
            && (audio_codec == AV_CODEC_ID_AAC
                || audio_codec == AV_CODEC_ID_ALAC)
        )
        || (container == ILLUCET_MEDIA_CONTAINER_FLAC
            && audio_codec == AV_CODEC_ID_FLAC);
    bool has_video = false;
    if (media_input.format->nb_streams > 128) {
        status = illucet_error(ILLUCET_FFMPEG_INPUT_ERROR, error, "Artwork input exceeds the stream bound");
        goto cleanup;
    }
    for (unsigned int i = 0; i < media_input.format->nb_streams; i++) {
        AVStream *stream = media_input.format->streams[i];
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO
            && !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            has_video = true;
        }
    }
    if (artwork_index < 0
        || (has_video && container != ILLUCET_MEDIA_CONTAINER_MP4)
        || (!has_video && (audio_index < 0 || !compatible_audio))) {
        status = illucet_error(ILLUCET_FFMPEG_INPUT_ERROR, error,
            "The media codec, container, and artwork are not compatible");
        goto cleanup;
    }
    enum AVCodecID image_codec = artwork_input.format->streams[artwork_index]->codecpar->codec_id;
    if (image_codec != AV_CODEC_ID_MJPEG && image_codec != AV_CODEC_ID_PNG) {
        status = illucet_error(ILLUCET_FFMPEG_INPUT_ERROR, error, "Embedded artwork requires JPEG or PNG");
        goto cleanup;
    }
    status = illucet_alloc_output(
        output_path,
        illucet_container_format_name(container),
        &partial,
        &output,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }
    // Preserve every video/audio/subtitle stream for video covers. Existing
    // audio-only attachment keeps its selected best audio stream contract.
    for (unsigned int i = 0; i < media_input.format->nb_streams; i++) {
        AVStream *source = media_input.format->streams[i];
        if (source->disposition & AV_DISPOSITION_ATTACHED_PIC) { continue; }
        enum AVMediaType type = source->codecpar->codec_type;
        if (has_video) {
            if (type != AVMEDIA_TYPE_VIDEO && type != AVMEDIA_TYPE_AUDIO
                && type != AVMEDIA_TYPE_SUBTITLE) { continue; }
        } else if ((int)i != audio_index) { continue; }
        AVStream *destination = avformat_new_stream(output, NULL);
        if (destination == NULL) {
            status = illucet_error(ILLUCET_FFMPEG_OUT_OF_MEMORY, error, "Cannot allocate artwork media stream");
            goto cleanup;
        }
        int copy_result = avcodec_parameters_copy(destination->codecpar, source->codecpar);
        if (copy_result < 0) {
            status = illucet_av_error(ILLUCET_FFMPEG_PROCESSING_ERROR, error, copy_result, "Cannot copy artwork media stream");
            goto cleanup;
        }
        destination->codecpar->codec_tag = 0;
        destination->time_base = source->time_base;
        destination->avg_frame_rate = source->avg_frame_rate;
        destination->sample_aspect_ratio = source->sample_aspect_ratio;
        destination->disposition = source->disposition;
        av_dict_copy(&destination->metadata, source->metadata, 0);
        stream_map[i] = destination->index;
    }
    if (has_video && media_input.format->nb_chapters > 0) {
        unsigned int count = media_input.format->nb_chapters;
        if (count > ILLUCET_ARTWORK_MAX_CHAPTERS) {
            status = illucet_error(ILLUCET_FFMPEG_INPUT_ERROR, error, "Artwork input exceeds the chapter bound");
            goto cleanup;
        }
        output->chapters = av_calloc(count, sizeof(*output->chapters));
        if (output->chapters == NULL) {
            status = illucet_error(ILLUCET_FFMPEG_OUT_OF_MEMORY, error, "Cannot allocate artwork chapter table");
            goto cleanup;
        }
        for (unsigned int i = 0; i < count; i++) {
            const AVChapter *source = media_input.format->chapters[i];
            AVChapter *chapter = av_mallocz(sizeof(*chapter));
            if (chapter == NULL) {
                status = illucet_error(ILLUCET_FFMPEG_OUT_OF_MEMORY, error, "Cannot copy artwork chapter");
                goto cleanup;
            }
            chapter->id = source->id;
            chapter->time_base = source->time_base;
            chapter->start = source->start;
            chapter->end = source->end;
            av_dict_copy(&chapter->metadata, source->metadata, 0);
            output->chapters[output->nb_chapters++] = chapter;
        }
    }
    AVStream *input_artwork = artwork_input.format->streams[artwork_index];
    AVStream *output_artwork = avformat_new_stream(output, NULL);
    if (output_artwork == NULL) {
        status = illucet_error(ILLUCET_FFMPEG_OUT_OF_MEMORY, error, "Cannot allocate artwork output stream");
        goto cleanup;
    }
    int result = avcodec_parameters_copy(output_artwork->codecpar, input_artwork->codecpar);
    if (result < 0) {
        status = illucet_av_error(ILLUCET_FFMPEG_PROCESSING_ERROR, error, result, "Cannot copy artwork stream parameters");
        goto cleanup;
    }
    output_artwork->codecpar->codec_tag = 0;
    output_artwork->time_base = input_artwork->time_base;
    output_artwork->disposition |= AV_DISPOSITION_ATTACHED_PIC;
    av_dict_set(&output_artwork->metadata, "title", "Cover", 0);
    av_dict_set(&output_artwork->metadata, "comment", "Cover (front)", 0);
    illucet_apply_metadata(
        output,
        media_input.format,
        metadata,
        container,
        "Illucet artwork attachment"
    );
    result = illucet_write_output_header(
        output,
        container,
        fast_start,
        false
    );
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot write artwork output header"
        );
        goto cleanup;
    }
    packet = av_packet_alloc();
    if (packet == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate artwork packet"
        );
        goto cleanup;
    }
    while (true) {
        result = av_read_frame(artwork_input.format, packet);
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_INPUT_ERROR,
                error,
                result,
                "Cannot read artwork packet"
            );
            goto cleanup;
        }
        if (packet->stream_index == artwork_index) {
            break;
        }
        av_packet_unref(packet);
    }
    if (packet->size <= 0 || packet->size > ILLUCET_MAX_ARTWORK_BYTES) {
        status = illucet_error(
            ILLUCET_FFMPEG_INPUT_ERROR,
            error,
            "Artwork packet is empty or exceeds the 16 MiB bound"
        );
        goto cleanup;
    }
    packet->stream_index = output_artwork->index;
    packet->pts = 0;
    packet->dts = 0;
    packet->duration = 0;
    packet->pos = -1;
    result = av_interleaved_write_frame(output, packet);
    av_packet_unref(packet);
    if (result < 0) {
        status = illucet_av_error(
            ILLUCET_FFMPEG_PROCESSING_ERROR,
            error,
            result,
            "Cannot write attached artwork"
        );
        goto cleanup;
    }
    if (illucet_progress(job, "artwork", 0.10)) {
        status = illucet_error(ILLUCET_FFMPEG_CANCELLED, error, "Cancelled");
        goto cleanup;
    }
    double duration = illucet_duration_seconds(media_input.format);
    while (true) {
        result = av_read_frame(media_input.format, packet);
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
                    "Cannot read artwork media input"
                );
            }
            goto cleanup;
        }
        if (packet->stream_index < 0 || packet->stream_index >= 128
            || (unsigned int)packet->stream_index >= media_input.format->nb_streams) {
            status = illucet_error(ILLUCET_FFMPEG_INPUT_ERROR, error, "Invalid artwork media packet stream");
            goto cleanup;
        }
        int destination_index = stream_map[packet->stream_index];
        if (destination_index < 0) {
            av_packet_unref(packet);
            continue;
        }
        AVStream *input_stream = media_input.format->streams[packet->stream_index];
        AVStream *output_stream = output->streams[destination_index];
        int64_t timestamp = illucet_packet_timestamp(packet);
        av_packet_rescale_ts(
            packet,
            input_stream->time_base,
            output_stream->time_base
        );
        packet->stream_index = destination_index;
        packet->pos = -1;
        result = av_interleaved_write_frame(output, packet);
        av_packet_unref(packet);
        if (result < 0) {
            status = illucet_av_error(
                ILLUCET_FFMPEG_PROCESSING_ERROR,
                error,
                result,
                "Cannot copy artwork media packet"
            );
            goto cleanup;
        }
        double progress = -1.0;
        if (duration > 0.0) {
            progress =
                0.10
                + 0.90 * timestamp * av_q2d(input_stream->time_base) / duration;
        }
        if (illucet_progress(
                job,
                "artwork",
                illucet_intermediate_progress(progress)
            )) {
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
            "Cannot finalize artwork output"
        );
        goto cleanup;
    }
    illucet_free_output(&output, &partial, false);
    status = illucet_partial_commit(&partial, error);
    if (status == ILLUCET_FFMPEG_OK) {
        illucet_progress(job, "artwork", 1.0);
    }

cleanup:
    av_packet_free(&packet);
    if (output != NULL) {
        illucet_free_output(&output, &partial, true);
    }
    illucet_close_input(&artwork_input);
    illucet_close_input(&media_input);
    return status;
}

IllucetFFmpegStatus illucet_ffmpeg_attach_mp3_artwork(
    const char *mp3_path,
    const char *jpeg_path,
    const char *output_path,
    IllucetFFmpegJob *job,
    char **error
) {
    IllucetMediaMetadata metadata;
    memset(&metadata, 0, sizeof(metadata));
    metadata.preserve_source_metadata = true;
    metadata.comment = "Artwork embedded by Illucet";
    return illucet_ffmpeg_attach_artwork(
        mp3_path,
        jpeg_path,
        output_path,
        ILLUCET_MEDIA_CONTAINER_MP3,
        false,
        &metadata,
        job,
        error
    );
}
