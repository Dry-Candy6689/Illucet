#ifndef ILLUCET_WEBKIT_BRIDGE_H
#define ILLUCET_WEBKIT_BRIDGE_H
#include "IllucetQuickJSBridge.h"
int32_t illucet_webkit_evaluate(const char *source, size_t source_length,
    uint32_t timeout_milliseconds, size_t output_limit,
    bool (*is_cancelled)(void *), void *context,
    char **output, size_t *output_length, char **error_message);
#endif
