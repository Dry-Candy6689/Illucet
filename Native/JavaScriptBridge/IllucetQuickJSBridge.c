#include "IllucetQuickJSBridge.h"

#include <quickjs.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
    char *bytes;
    size_t length;
    size_t capacity;
    size_t limit;
    uint64_t deadline_nanoseconds;
    IllucetQuickJSCancelCallback cancel_callback;
    void *cancel_context;
    bool timed_out;
    bool cancelled;
    bool output_exceeded;
} IllucetQuickJSEvaluation;

#define ILLUCET_STRINGIFY_INNER(value) #value
#define ILLUCET_STRINGIFY(value) ILLUCET_STRINGIFY_INNER(value)

static char *illucet_quickjs_copy_string(const char *value) {
    if (value == NULL) {
        return NULL;
    }
    size_t length = strlen(value);
    char *copy = malloc(length + 1);
    if (copy != NULL) {
        memcpy(copy, value, length + 1);
    }
    return copy;
}

static void illucet_quickjs_assign_error(
    char **destination,
    const char *message
) {
    if (destination != NULL) {
        *destination = illucet_quickjs_copy_string(
            message == NULL ? "Unknown QuickJS error." : message
        );
    }
}

static uint64_t illucet_quickjs_monotonic_nanoseconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return ((uint64_t)now.tv_sec * 1000000000ULL) +
        (uint64_t)now.tv_nsec;
}

static bool illucet_quickjs_append(
    IllucetQuickJSEvaluation *evaluation,
    const char *bytes,
    size_t length
) {
    if (length > evaluation->limit ||
        evaluation->length > evaluation->limit - length) {
        evaluation->output_exceeded = true;
        return false;
    }

    size_t required = evaluation->length + length + 1;
    if (required > evaluation->capacity) {
        size_t new_capacity = evaluation->capacity == 0
            ? 256
            : evaluation->capacity;
        while (new_capacity < required) {
            if (new_capacity > evaluation->limit / 2) {
                new_capacity = evaluation->limit + 1;
                break;
            }
            new_capacity *= 2;
        }

        char *resized = realloc(evaluation->bytes, new_capacity);
        if (resized == NULL) {
            return false;
        }
        evaluation->bytes = resized;
        evaluation->capacity = new_capacity;
    }

    memcpy(evaluation->bytes + evaluation->length, bytes, length);
    evaluation->length += length;
    evaluation->bytes[evaluation->length] = '\0';
    return true;
}

static JSValue illucet_quickjs_console_log(
    JSContext *context,
    JSValueConst this_value,
    int argument_count,
    JSValueConst *arguments
) {
    (void)this_value;
    IllucetQuickJSEvaluation *evaluation = JS_GetContextOpaque(context);
    if (evaluation == NULL) {
        return JS_ThrowInternalError(
            context,
            "Illucet QuickJS capture context is missing"
        );
    }

    for (int index = 0; index < argument_count; index += 1) {
        size_t length = 0;
        const char *text = JS_ToCStringLen(
            context,
            &length,
            arguments[index]
        );
        if (text == NULL) {
            return JS_EXCEPTION;
        }

        bool appended = true;
        if (index > 0) {
            appended = illucet_quickjs_append(evaluation, " ", 1);
        }
        if (appended) {
            appended = illucet_quickjs_append(evaluation, text, length);
        }
        JS_FreeCString(context, text);
        if (!appended) {
            return JS_ThrowInternalError(
                context,
                evaluation->output_exceeded
                    ? "Illucet QuickJS output limit exceeded"
                    : "Illucet QuickJS output allocation failed"
            );
        }
    }

    if (!illucet_quickjs_append(evaluation, "\n", 1)) {
        return JS_ThrowInternalError(
            context,
            evaluation->output_exceeded
                ? "Illucet QuickJS output limit exceeded"
                : "Illucet QuickJS output allocation failed"
        );
    }
    return JS_UNDEFINED;
}

static bool illucet_quickjs_install_console(
    JSContext *context,
    char **error_message
) {
    JSValue global = JS_GetGlobalObject(context);
    JSValue console = JS_NewObject(context);
    JSValue log_function = JS_NewCFunction(
        context,
        illucet_quickjs_console_log,
        "log",
        1
    );

    if (JS_IsException(global) ||
        JS_IsException(console) ||
        JS_IsException(log_function)) {
        JS_FreeValue(context, log_function);
        JS_FreeValue(context, console);
        JS_FreeValue(context, global);
        illucet_quickjs_assign_error(
            error_message,
            "Could not create the restricted QuickJS console."
        );
        return false;
    }

    if (JS_SetPropertyStr(context, console, "log", log_function) < 0) {
        JS_FreeValue(context, console);
        JS_FreeValue(context, global);
        illucet_quickjs_assign_error(
            error_message,
            "Could not install the restricted QuickJS console."
        );
        return false;
    }
    if (JS_SetPropertyStr(context, global, "console", console) < 0) {
        JS_FreeValue(context, global);
        illucet_quickjs_assign_error(
            error_message,
            "Could not install the restricted QuickJS console."
        );
        return false;
    }
    JSValue print_function = JS_NewCFunction(
        context,
        illucet_quickjs_console_log,
        "print",
        1
    );
    if (JS_IsException(print_function)) {
        JS_FreeValue(context, print_function);
        JS_FreeValue(context, global);
        illucet_quickjs_assign_error(
            error_message,
            "Could not create the restricted QuickJS print helper."
        );
        return false;
    }
    if (JS_SetPropertyStr(
            context,
            global,
            "print",
            print_function
        ) < 0) {
        JS_FreeValue(context, global);
        illucet_quickjs_assign_error(
            error_message,
            "Could not install the restricted QuickJS print helper."
        );
        return false;
    }

    JSValue script_arguments = JS_NewArray(context);
    if (JS_IsException(script_arguments)) {
        JS_FreeValue(context, script_arguments);
        JS_FreeValue(context, global);
        illucet_quickjs_assign_error(
            error_message,
            "Could not create restricted QuickJS script arguments."
        );
        return false;
    }
    if (JS_SetPropertyStr(
            context,
            global,
            "scriptArgs",
            script_arguments
        ) < 0) {
        JS_FreeValue(context, global);
        illucet_quickjs_assign_error(
            error_message,
            "Could not install restricted QuickJS script arguments."
        );
        return false;
    }

    JS_FreeValue(context, global);
    return true;
}

static int illucet_quickjs_interrupt(
    JSContext *context,
    void *opaque
) {
    (void)context;
    IllucetQuickJSEvaluation *evaluation = opaque;

    if (evaluation->cancel_callback != NULL &&
        evaluation->cancel_callback(evaluation->cancel_context)) {
        evaluation->cancelled = true;
        return 1;
    }

    uint64_t now = illucet_quickjs_monotonic_nanoseconds();
    if (now == 0 || now >= evaluation->deadline_nanoseconds) {
        evaluation->timed_out = true;
        return 1;
    }
    return 0;
}

static char *illucet_quickjs_exception_message(JSContext *context) {
    JSValue exception = JS_GetException(context);

    size_t length = 0;
    const char *rendered = JS_ToCStringLen(
        context,
        &length,
        exception
    );
    if (rendered == NULL) {
        JS_FreeValue(context, exception);
        return illucet_quickjs_copy_string(
            "QuickJS exception could not be rendered."
        );
    }

    const char *safe_message = NULL;
    if (strstr(rendered, "unexpected structure") != NULL) {
        safe_message = "QuickJS EJS error: unexpected player structure.";
    } else if (strstr(rendered, "no solutions:") != NULL) {
        safe_message = "QuickJS EJS error: no challenge solution.";
    } else if (strstr(rendered, "invalid solutions:") != NULL) {
        safe_message = "QuickJS EJS error: conflicting challenge solutions.";
    } else if (strstr(rendered, "Failed to extract") != NULL) {
        safe_message = "QuickJS EJS error: challenge extraction failed.";
    } else if (JS_IsError(exception)) {
        JSValue name_value = JS_GetPropertyStr(context, exception, "name");
        const char *name = JS_IsException(name_value)
            ? NULL
            : JS_ToCString(context, name_value);
        if (name != NULL && strcmp(name, "SyntaxError") == 0) {
            safe_message = "QuickJS exception: SyntaxError.";
        } else if (name != NULL && strcmp(name, "ReferenceError") == 0) {
            safe_message = "QuickJS exception: ReferenceError.";
        } else if (name != NULL && strcmp(name, "TypeError") == 0) {
            safe_message = "QuickJS exception: TypeError.";
        } else if (name != NULL && strcmp(name, "RangeError") == 0) {
            safe_message = "QuickJS exception: RangeError.";
        } else if (name != NULL && strcmp(name, "InternalError") == 0) {
            safe_message = "QuickJS exception: InternalError.";
        } else if (name != NULL && strcmp(name, "EvalError") == 0) {
            safe_message = "QuickJS exception: EvalError.";
        } else {
            safe_message = "QuickJS exception: Error.";
        }
        if (name != NULL) {
            JS_FreeCString(context, name);
        }
        JS_FreeValue(context, name_value);
    } else {
        safe_message = "QuickJS threw an unclassified non-Error value.";
        if (JS_IsString(exception)) {
            safe_message = "QuickJS threw a redacted string value.";
        } else if (JS_IsObject(exception)) {
            JSValue name_value = JS_GetPropertyStr(
                context,
                exception,
                "name"
            );
            const char *name = JS_IsException(name_value)
                ? NULL
                : JS_ToCString(context, name_value);
            if (name != NULL && strcmp(name, "ParseError") == 0) {
                safe_message = "QuickJS threw a ParseError object.";
            } else if (name != NULL && strcmp(name, "SyntaxError") == 0) {
                safe_message = "QuickJS threw a SyntaxError object.";
            } else if (name != NULL && strcmp(name, "TypeError") == 0) {
                safe_message = "QuickJS threw a TypeError object.";
            } else {
                safe_message = "QuickJS threw a redacted object value.";
            }
            if (name != NULL) {
                JS_FreeCString(context, name);
            }
            JS_FreeValue(context, name_value);
        } else if (JS_IsNumber(exception)) {
            safe_message = "QuickJS threw a redacted numeric value.";
        } else if (JS_IsBool(exception)) {
            safe_message = "QuickJS threw a redacted Boolean value.";
        } else if (JS_IsNull(exception)) {
            safe_message = "QuickJS threw null.";
        } else if (JS_IsUndefined(exception)) {
            safe_message = "QuickJS threw undefined.";
        }
    }

    JS_FreeCString(context, rendered);
    JS_FreeValue(context, exception);
    return illucet_quickjs_copy_string(safe_message);
}

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
) {
    if (output != NULL) {
        *output = NULL;
    }
    if (output_length != NULL) {
        *output_length = 0;
    }
    if (error_message != NULL) {
        *error_message = NULL;
    }
    if (source == NULL ||
        source_length == 0 ||
        memory_limit_bytes == 0 ||
        stack_limit_bytes == 0 ||
        timeout_milliseconds == 0 ||
        output_limit_bytes == 0) {
        illucet_quickjs_assign_error(
            error_message,
            "QuickJS evaluation arguments are invalid."
        );
        return ILLUCET_QUICKJS_ERROR;
    }

    uint64_t started = illucet_quickjs_monotonic_nanoseconds();
    if (started == 0) {
        illucet_quickjs_assign_error(
            error_message,
            "Could not read a monotonic clock for QuickJS."
        );
        return ILLUCET_QUICKJS_ERROR;
    }

    IllucetQuickJSEvaluation evaluation = {
        .bytes = NULL,
        .length = 0,
        .capacity = 0,
        .limit = output_limit_bytes,
        .deadline_nanoseconds = started +
            ((uint64_t)timeout_milliseconds * 1000000ULL),
        .cancel_callback = cancel_callback,
        .cancel_context = cancel_context,
        .timed_out = false,
        .cancelled = false,
        .output_exceeded = false
    };

    JSRuntime *runtime = JS_NewRuntime();
    if (runtime == NULL) {
        illucet_quickjs_assign_error(
            error_message,
            "JS_NewRuntime failed."
        );
        return ILLUCET_QUICKJS_ERROR;
    }
    JS_SetMemoryLimit(runtime, memory_limit_bytes);
    JS_SetMaxStackSize(runtime, stack_limit_bytes);
    JS_SetCanBlock(runtime, false);
    JS_SetInterruptHandler(runtime, illucet_quickjs_interrupt, &evaluation);

    JSContext *context = JS_NewContext(runtime);
    if (context == NULL) {
        JS_FreeRuntime(runtime);
        illucet_quickjs_assign_error(
            error_message,
            "JS_NewContext failed."
        );
        return ILLUCET_QUICKJS_ERROR;
    }
    JS_SetContextOpaque(context, &evaluation);

    int32_t result_code = ILLUCET_QUICKJS_OK;
    char *local_error = NULL;
    if (!illucet_quickjs_install_console(context, &local_error)) {
        result_code = ILLUCET_QUICKJS_ERROR;
    } else {
        JSValue result = JS_Eval(
            context,
            source,
            source_length,
            "<illucet-ejs>",
            JS_EVAL_TYPE_GLOBAL
        );
        if (JS_IsException(result)) {
            local_error = illucet_quickjs_exception_message(context);
            result_code = ILLUCET_QUICKJS_ERROR;
        }
        JS_FreeValue(context, result);

        while (result_code == ILLUCET_QUICKJS_OK) {
            JSContext *job_context = NULL;
            int pending_result = JS_ExecutePendingJob(
                runtime,
                &job_context
            );
            if (pending_result == 0) {
                break;
            }
            if (pending_result < 0) {
                local_error = illucet_quickjs_exception_message(
                    job_context == NULL ? context : job_context
                );
                result_code = ILLUCET_QUICKJS_ERROR;
                break;
            }
        }
    }

    if (result_code == ILLUCET_QUICKJS_OK &&
        evaluation.cancel_callback != NULL &&
        evaluation.cancel_callback(evaluation.cancel_context)) {
        evaluation.cancelled = true;
    }
    if (result_code == ILLUCET_QUICKJS_OK && !evaluation.cancelled) {
        uint64_t finished = illucet_quickjs_monotonic_nanoseconds();
        if (finished == 0 || finished >= evaluation.deadline_nanoseconds) {
            evaluation.timed_out = true;
        }
    }

    if (evaluation.cancelled) {
        result_code = ILLUCET_QUICKJS_CANCELLED;
        free(local_error);
        local_error = illucet_quickjs_copy_string(
            "QuickJS evaluation was cancelled."
        );
    } else if (evaluation.timed_out) {
        result_code = ILLUCET_QUICKJS_TIMEOUT;
        free(local_error);
        local_error = illucet_quickjs_copy_string(
            "QuickJS evaluation exceeded its time limit."
        );
    } else if (evaluation.output_exceeded) {
        result_code = ILLUCET_QUICKJS_OUTPUT_LIMIT;
        free(local_error);
        local_error = illucet_quickjs_copy_string(
            "QuickJS evaluation exceeded its output limit."
        );
    }

    JS_SetContextOpaque(context, NULL);
    JS_FreeContext(context);
    JS_FreeRuntime(runtime);

    if (result_code == ILLUCET_QUICKJS_OK) {
        if (evaluation.bytes == NULL) {
            evaluation.bytes = illucet_quickjs_copy_string("");
        }
        if (evaluation.bytes == NULL) {
            result_code = ILLUCET_QUICKJS_ERROR;
            local_error = illucet_quickjs_copy_string(
                "Could not allocate QuickJS output."
            );
        } else if (output != NULL) {
            *output = evaluation.bytes;
            if (output_length != NULL) {
                *output_length = evaluation.length;
            }
            evaluation.bytes = NULL;
        }
    }

    if (result_code != ILLUCET_QUICKJS_OK && error_message != NULL) {
        *error_message = local_error == NULL
            ? illucet_quickjs_copy_string("Unknown QuickJS evaluation error.")
            : local_error;
        local_error = NULL;
    }

    free(evaluation.bytes);
    free(local_error);
    return result_code;
}

const char *illucet_quickjs_version(void) {
    return ILLUCET_STRINGIFY(QJS_VERSION_MAJOR) "." \
        ILLUCET_STRINGIFY(QJS_VERSION_MINOR) "." \
        ILLUCET_STRINGIFY(QJS_VERSION_PATCH) QJS_VERSION_SUFFIX;
}

void illucet_quickjs_string_free(char *value) {
    free(value);
}
