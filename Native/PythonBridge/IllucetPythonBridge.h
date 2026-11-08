#ifndef ILLUCET_PYTHON_BRIDGE_H
#define ILLUCET_PYTHON_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct IllucetPythonEngine IllucetPythonEngine;

typedef void (*IllucetPythonEventCallback)(
    void *context,
    uint64_t request_id,
    const char *utf8,
    size_t length
);

enum {
    ILLUCET_PYTHON_OK = 0,
    ILLUCET_PYTHON_ERROR = 1,
    ILLUCET_PYTHON_CANCELLED = 2,
    ILLUCET_PYTHON_NOT_RUNNING = 3
};

IllucetPythonEngine *illucet_python_engine_create(
    const char *python_home,
    const char *bundled_app_path,
    const char *bundled_packages_path,
    const char *writable_packages_path,
    IllucetPythonEventCallback event_callback,
    void *event_context
);

int32_t illucet_python_engine_start(
    IllucetPythonEngine *engine,
    char **error_message
);

int32_t illucet_python_engine_execute(
    IllucetPythonEngine *engine,
    uint64_t request_id,
    const char *request_json,
    char **response_json,
    char **error_message
);

void illucet_python_engine_cancel(
    IllucetPythonEngine *engine,
    uint64_t request_id
);

int32_t illucet_python_engine_shutdown(
    IllucetPythonEngine *engine,
    char **error_message
);

void illucet_python_engine_destroy(IllucetPythonEngine *engine);
void illucet_python_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
