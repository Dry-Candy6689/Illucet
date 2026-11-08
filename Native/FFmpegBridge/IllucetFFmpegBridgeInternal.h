#ifndef ILLUCET_FFMPEG_BRIDGE_INTERNAL_H
#define ILLUCET_FFMPEG_BRIDGE_INTERNAL_H

#include "IllucetFFmpegBridge.h"

#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/avstring.h>
#include <libavutil/bprint.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/imgutils.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libavutil/sha.h>
#include <libavutil/time.h>
#include <libavutil/version.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <math.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#define ILLUCET_FIXTURE_SECONDS 2
#define ILLUCET_VIDEO_WIDTH 320
#define ILLUCET_VIDEO_HEIGHT 180
#define ILLUCET_VIDEO_FPS 30
#define ILLUCET_AUDIO_RATE 48000
#define ILLUCET_MAX_ARTWORK_BYTES (16 * 1024 * 1024)

typedef struct IllucetPartialOutput {
    char path[PATH_MAX];
    const char *final_path;
    bool active;
} IllucetPartialOutput;

typedef struct IllucetInput {
    AVFormatContext *format;
    IllucetFFmpegJob *job;
} IllucetInput;

void illucet_clear_error(char **error);

IllucetFFmpegStatus illucet_error(
    IllucetFFmpegStatus status,
    char **error,
    const char *format,
    ...
) __attribute__((format(printf, 3, 4)));

IllucetFFmpegStatus illucet_av_error(
    IllucetFFmpegStatus status,
    char **error,
    int av_error,
    const char *operation
);

bool illucet_job_cancelled(IllucetFFmpegJob *job);
bool illucet_progress(IllucetFFmpegJob *job, const char *stage, double progress);
double illucet_intermediate_progress(double progress);
void illucet_job_set_poll_only(IllucetFFmpegJob *job, bool poll_only);

void illucet_json_string(AVBPrint *print, const char *value);
bool illucet_path_is_valid(const char *path);

IllucetFFmpegStatus illucet_partial_begin(
    const char *final_path,
    IllucetPartialOutput *partial,
    char **error
);
void illucet_partial_discard(IllucetPartialOutput *partial);
IllucetFFmpegStatus illucet_partial_commit(
    IllucetPartialOutput *partial,
    char **error
);

IllucetFFmpegStatus illucet_open_input(
    const char *path,
    IllucetFFmpegJob *job,
    IllucetInput *input,
    char **error
);
IllucetFFmpegStatus illucet_open_input_with_limits(
    const char *path,
    IllucetFFmpegJob *job,
    IllucetInput *input,
    int64_t probe_size,
    int64_t max_analyze_duration,
    int max_probe_packets,
    bool export_all_metadata,
    char **error
);
void illucet_close_input(IllucetInput *input);

IllucetFFmpegStatus illucet_alloc_output(
    const char *final_path,
    const char *format_name,
    IllucetPartialOutput *partial,
    AVFormatContext **output,
    char **error
);
void illucet_free_output(
    AVFormatContext **output,
    IllucetPartialOutput *partial,
    bool discard
);

double illucet_duration_seconds(const AVFormatContext *format);
enum AVSampleFormat illucet_pick_sample_format(
    const AVCodec *codec,
    enum AVSampleFormat preferred
);
int64_t illucet_packet_timestamp(const AVPacket *packet);
int illucet_write_encoded_packets(
    AVCodecContext *encoder,
    AVStream *stream,
    AVFormatContext *output,
    AVFrame *frame
);
const char *illucet_container_format_name(IllucetMediaContainer container);
bool illucet_container_supports_fast_start(IllucetMediaContainer container);

void illucet_apply_metadata(
    AVFormatContext *output,
    const AVFormatContext *input,
    const IllucetMediaMetadata *metadata,
    IllucetMediaContainer container,
    const char *encoder_name
);

int illucet_write_output_header(
    AVFormatContext *output,
    IllucetMediaContainer container,
    bool fast_start,
    bool use_metadata_tags
);

#endif
