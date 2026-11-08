#ifndef ILLUCET_QUICKJS_BRIDGE_H
#define ILLUCET_QUICKJS_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef bool (*IllucetQuickJSCancelCallback)(void *context);

enum {
    ILLUCET_QUICKJS_OK = 0,
    ILLUCET_QUICKJS_ERROR = 1,
    ILLUCET_QUICKJS_TIMEOUT = 2,
    ILLUCET_QUICKJS_CANCELLED = 3,
    ILLUCET_QUICKJS_OUTPUT_LIMIT = 4
};

int32_t illucet_quickjs_evaluate(
    const char *source,
    size_t source_length,
    size_t memory_limit_bytes,
    size_t stack_limit_bytes,
    uint32_t timeout_milliseconds,
    size_t output_limit_bytes,
    IllucetQuickJSCancelCallback cancel_callback,
    void *cancel_context,
    char **output,
    size_t *output_length,
    char **error_message
);

const char *illucet_quickjs_version(void);
void illucet_quickjs_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
