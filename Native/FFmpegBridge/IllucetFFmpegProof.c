#include "IllucetFFmpegBridgeInternal.h"

static IllucetFFmpegStatus illucet_make_proof_directory(
    const char *root,
    char directory[PATH_MAX],
    char **error
) {
    if (!illucet_path_is_valid(root)) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "A valid Stage 0 output directory is required"
        );
    }
    struct stat root_status;
    if (stat(root, &root_status) != 0 || !S_ISDIR(root_status.st_mode)) {
        return illucet_error(
            ILLUCET_FFMPEG_IO_ERROR,
            error,
            "Stage 0 output root does not exist or is not a directory"
        );
    }
    for (int attempt = 0; attempt < 32; attempt++) {
        uint32_t first = arc4random();
        uint32_t second = arc4random();
        int written = snprintf(
            directory,
            PATH_MAX,
            "%s/Stage0FFmpeg-%08x%08x",
            root,
            first,
            second
        );
        if (written < 0 || written >= PATH_MAX) {
            return illucet_error(
                ILLUCET_FFMPEG_INVALID_ARGUMENT,
                error,
                "Stage 0 output path is too long"
            );
        }
        if (mkdir(directory, S_IRWXU) == 0) {
            return ILLUCET_FFMPEG_OK;
        }
        if (errno != EEXIST) {
            return illucet_error(
                ILLUCET_FFMPEG_IO_ERROR,
                error,
                "Cannot create Stage 0 output directory: %s",
                strerror(errno)
            );
        }
    }
    return illucet_error(
        ILLUCET_FFMPEG_IO_ERROR,
        error,
        "Cannot allocate a unique Stage 0 directory"
    );
}

static IllucetFFmpegStatus illucet_proof_path(
    char path[PATH_MAX],
    const char *directory,
    const char *name,
    char **error
) {
    int written = snprintf(path, PATH_MAX, "%s/%s", directory, name);
    if (written < 0 || written >= PATH_MAX) {
        return illucet_error(
            ILLUCET_FFMPEG_INVALID_ARGUMENT,
            error,
            "Stage 0 fixture path is too long"
        );
    }
    return ILLUCET_FFMPEG_OK;
}

IllucetFFmpegStatus illucet_ffmpeg_run_stage0_proof(
    const char *output_directory,
    IllucetFFmpegProgressCallback progress_callback,
    void *progress_context,
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
    IllucetFFmpegJob *job = illucet_ffmpeg_job_create(
        progress_callback,
        progress_context
    );
    if (job == NULL) {
        return illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot allocate Stage 0 job"
        );
    }

    static const char *identifiers[] = {
        "fixture-video",
        "fixture-audio",
        "fixture-incompatible",
        "fixture-artwork",
        "merge",
        "audio-copy",
        "video-only",
        "mp3-128k",
        "compatible-mp4",
        "mp3-artwork"
    };
    static const char *progress_stages[] = {
        "fixture-video",
        "fixture-audio",
        "fixture-incompatible",
        "fixture-artwork",
        "merge",
        "audio-copy",
        "video-only",
        "audio-mp3",
        "video-transcode",
        "artwork"
    };
    static const char *filenames[] = {
        "fixture-video.mp4",
        "fixture-audio.m4a",
        "fixture-incompatible.mkv",
        "fixture-artwork.jpg",
        "merged.mp4",
        "audio-copy.m4a",
        "video-only.mp4",
        "audio-128k.mp3",
        "compatible.mp4",
        "audio-artwork.mp3"
    };
    enum { ILLUCET_PROOF_OUTPUT_COUNT = 10 };
    char directory[PATH_MAX] = {0};
    char paths[ILLUCET_PROOF_OUTPUT_COUNT][PATH_MAX];
    memset(paths, 0, sizeof(paths));
    char *probes[ILLUCET_PROOF_OUTPUT_COUNT];
    memset(probes, 0, sizeof(probes));

    IllucetFFmpegStatus status = illucet_make_proof_directory(
        output_directory,
        directory,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }
    for (int index = 0; index < ILLUCET_PROOF_OUTPUT_COUNT; index++) {
        status = illucet_proof_path(
            paths[index],
            directory,
            filenames[index],
            error
        );
        if (status != ILLUCET_FFMPEG_OK) {
            goto cleanup;
        }
    }

    status = illucet_ffmpeg_generate_fixtures(
        paths[0],
        paths[1],
        paths[2],
        paths[3],
        job,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }
    status = illucet_ffmpeg_merge_stream_copy(
        paths[0],
        paths[1],
        paths[4],
        job,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }
    status = illucet_ffmpeg_extract_audio_copy(
        paths[2],
        paths[5],
        job,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }
    status = illucet_ffmpeg_copy_video_only(
        paths[0],
        paths[6],
        job,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }
    status = illucet_ffmpeg_transcode_audio_mp3(
        paths[1],
        paths[7],
        128000,
        job,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }
    status = illucet_ffmpeg_transcode_compatible_mp4(
        paths[2],
        paths[8],
        job,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }
    status = illucet_ffmpeg_attach_mp3_artwork(
        paths[7],
        paths[3],
        paths[9],
        job,
        error
    );
    if (status != ILLUCET_FFMPEG_OK) {
        goto cleanup;
    }
    /*
     * The proof callback reports the ten user-visible operations exactly once
     * as monotonic stage sequences. Full-decode probing is still cancellable
     * through callback polls with a NULL stage, but its internal generic
     * "probe" stage is hidden so it cannot reset a completed operation.
     */
    illucet_job_set_poll_only(job, true);
    for (int index = 0; index < ILLUCET_PROOF_OUTPUT_COUNT; index++) {
        status = illucet_ffmpeg_probe_json(
            paths[index],
            job,
            &probes[index],
            error
        );
        if (status != ILLUCET_FFMPEG_OK) {
            illucet_job_set_poll_only(job, false);
            goto cleanup;
        }
    }
    illucet_job_set_poll_only(job, false);

    AVBPrint print;
    av_bprint_init(&print, 16384, 4 * 1024 * 1024);
    av_bprintf(&print, "{\"ffmpegVersion\":");
    illucet_json_string(&print, av_version_info());
    av_bprintf(&print, ",\"configuration\":");
    illucet_json_string(&print, avcodec_configuration());
    av_bprintf(&print, ",\"outputDirectory\":");
    illucet_json_string(&print, directory);
    av_bprintf(&print, ",\"operations\":[");
    for (int index = 0; index < ILLUCET_PROOF_OUTPUT_COUNT; index++) {
        if (index > 0) {
            av_bprint_chars(&print, ',', 1);
        }
        av_bprintf(&print, "{\"id\":");
        illucet_json_string(&print, identifiers[index]);
        av_bprintf(&print, ",\"status\":\"PASS\",\"progressStage\":");
        illucet_json_string(&print, progress_stages[index]);
        av_bprint_chars(&print, '}', 1);
    }
    av_bprintf(&print, "],\"outputs\":[");
    for (int index = 0; index < ILLUCET_PROOF_OUTPUT_COUNT; index++) {
        if (index > 0) {
            av_bprint_chars(&print, ',', 1);
        }
        av_bprintf(&print, "{\"id\":");
        illucet_json_string(&print, identifiers[index]);
        av_bprintf(&print, ",\"path\":");
        illucet_json_string(&print, paths[index]);
        av_bprintf(&print, ",\"probe\":%s}", probes[index]);
    }
    av_bprintf(&print, "]}");
    if (!av_bprint_is_complete(&print)) {
        av_bprint_finalize(&print, NULL);
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Stage 0 proof JSON exceeded its 4 MiB bound"
        );
        goto cleanup;
    }
    av_bprint_finalize(&print, result_json);
    if (*result_json == NULL) {
        status = illucet_error(
            ILLUCET_FFMPEG_OUT_OF_MEMORY,
            error,
            "Cannot finalize Stage 0 proof JSON"
        );
        goto cleanup;
    }
    status = ILLUCET_FFMPEG_OK;

cleanup:
    for (int index = 0; index < ILLUCET_PROOF_OUTPUT_COUNT; index++) {
        av_free(probes[index]);
    }
    if (status != ILLUCET_FFMPEG_OK) {
        av_freep(result_json);
    }
    illucet_ffmpeg_job_destroy(job);
    return status;
}
