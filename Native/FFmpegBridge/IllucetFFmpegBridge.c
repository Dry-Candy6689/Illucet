#include "IllucetFFmpegBridgeInternal.h"

const char *illucet_ffmpeg_version(void) {
    return av_version_info();
}

const char *illucet_ffmpeg_configuration(void) {
    return avcodec_configuration();
}

IllucetFFmpegStatus illucet_ffmpeg_version_json(
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
    AVBPrint print;
    av_bprint_init(&print, 256, AV_BPRINT_SIZE_UNLIMITED);
    av_bprintf(&print, "{\"version\":");
    illucet_json_string(&print, av_version_info());
    av_bprintf(&print, ",\"avcodecVersion\":%u,\"avformatVersion\":%u,\"configuration\":",
               avcodec_version(), avformat_version());
    illucet_json_string(&print, avcodec_configuration());
    av_bprintf(&print, "}");
    if (!av_bprint_is_complete(&print)) {
        av_bprint_finalize(&print, NULL);
        return illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate version JSON"
        );
    }
    av_bprint_finalize(&print, result_json);
    return *result_json != NULL
        ? ILLUCET_FFMPEG_OK
        : illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot finalize version JSON"
        );
}
