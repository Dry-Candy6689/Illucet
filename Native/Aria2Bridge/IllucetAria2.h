#ifndef ILLUCET_ARIA2_H
#define ILLUCET_ARIA2_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct IllucetAria2Session IllucetAria2Session;
typedef struct {
    int32_t state; /* 0 pending, 1 complete, 2 failed, 3 removed */
    int32_t errorCode;
    int64_t completedBytes;
    int64_t totalBytes;
} IllucetAria2Snapshot;
/* Every function is called on the same serial worker. No process signal handlers. */
IllucetAria2Session *illucet_aria2_create(const char *caCertificate);
int32_t illucet_aria2_add(IllucetAria2Session *, const char *url, const char *directory,
                        const char *headers, int64_t speedLimit,
                        uint64_t *identifier);
int32_t illucet_aria2_poll(IllucetAria2Session *);
IllucetAria2Snapshot illucet_aria2_snapshot(IllucetAria2Session *, uint64_t identifier);
void illucet_aria2_cancel(IllucetAria2Session *, uint64_t identifier);
void illucet_aria2_close(IllucetAria2Session *);
const char *illucet_aria2_version(void);
#ifdef __cplusplus
}
#endif
#endif
