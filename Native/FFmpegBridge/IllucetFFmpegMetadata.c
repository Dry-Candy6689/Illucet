#include "IllucetFFmpegBridgeInternal.h"

bool illucet_container_supports_fast_start(
    IllucetMediaContainer container
) {
    return container == ILLUCET_MEDIA_CONTAINER_MP4
        || container == ILLUCET_MEDIA_CONTAINER_MOV
        || container == ILLUCET_MEDIA_CONTAINER_M4A;
}

void illucet_set_metadata_value(
    AVDictionary **dictionary,
    const char *key,
    const char *value
) {
    if (value != NULL && value[0] != '\0') {
        av_dict_set(dictionary, key, value, 0);
    }
}

void illucet_apply_metadata(
    AVFormatContext *output,
    const AVFormatContext *input,
    const IllucetMediaMetadata *metadata,
    IllucetMediaContainer container,
    const char *encoder_name
) {
    if (output == NULL) {
        return;
    }
    if (
        metadata != NULL
        && metadata->preserve_source_metadata
        && input != NULL
    ) {
        av_dict_copy(&output->metadata, input->metadata, 0);
    }
    if (metadata != NULL) {
        bool uses_comment_fallback =
            container == ILLUCET_MEDIA_CONTAINER_FLAC
            || container == ILLUCET_MEDIA_CONTAINER_OGG
            || container == ILLUCET_MEDIA_CONTAINER_WAV;
        if (uses_comment_fallback) {
            av_dict_set(&output->metadata, "description", NULL, 0);
            av_dict_set(&output->metadata, "comment", NULL, 0);
        }
        illucet_set_metadata_value(
            &output->metadata,
            "title",
            metadata->title
        );
        illucet_set_metadata_value(
            &output->metadata,
            "artist",
            metadata->artist
        );
        illucet_set_metadata_value(
            &output->metadata,
            "date",
            metadata->date
        );
        if (!uses_comment_fallback) {
            illucet_set_metadata_value(
                &output->metadata,
                "description",
                metadata->description
            );
        }
        illucet_set_metadata_value(
            &output->metadata,
            "comment",
            metadata->comment != NULL
                ? metadata->comment
                : metadata->description
        );
        illucet_set_metadata_value(
            &output->metadata,
            "source_url",
            metadata->source_url
        );
        illucet_set_metadata_value(
            &output->metadata,
            "video_id",
            metadata->video_id
        );
        illucet_set_metadata_value(
            &output->metadata,
            "channel",
            metadata->channel
        );
    }
    illucet_set_metadata_value(
        &output->metadata,
        "encoder",
        encoder_name
    );
}

int illucet_write_output_header(
    AVFormatContext *output,
    IllucetMediaContainer container,
    bool fast_start,
    bool use_metadata_tags
) {
    AVDictionary *options = NULL;
    if (illucet_container_supports_fast_start(container)) {
        const char *movflags;
        if (fast_start && use_metadata_tags) {
            movflags = "+faststart+use_metadata_tags";
        } else if (fast_start) {
            movflags = "+faststart";
        } else if (use_metadata_tags) {
            movflags = "+use_metadata_tags";
        } else {
            movflags = NULL;
        }
        av_dict_set(
            &options,
            "movflags",
            movflags,
            0
        );
    }
    if (container == ILLUCET_MEDIA_CONTAINER_MP3) {
        av_dict_set(&options, "id3v2_version", "3", 0);
    }
    int result = avformat_write_header(output, &options);
    av_dict_free(&options);
    return result;
}
