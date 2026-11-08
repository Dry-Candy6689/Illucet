#define PY_SSIZE_T_CLEAN
#include <Python/Python.h>

#include "IllucetPythonBridge.h"
#include "../JavaScriptBridge/IllucetQuickJSBridge.h"

#include <ctype.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ILLUCET_PYTHON_WORKER_STACK_SIZE (8U * 1024U * 1024U)
/* Account requests carry bounded in-memory cookies plus JSON escaping. */
#define ILLUCET_PYTHON_MAX_REQUEST_SIZE (512U * 1024U)
#define ILLUCET_PYTHON_MAX_EVENT_SIZE (64U * 1024U)
#define ILLUCET_PYTHON_MAX_RESPONSE_SIZE (8U * 1024U * 1024U)

typedef struct IllucetPythonJob {
    uint64_t request_id;
    char *request_json;
    char *response_json;
    char *error_message;
    int32_t result;
    atomic_bool cancelled;
    bool finished;
    pthread_cond_t completion_condition;
    struct IllucetPythonJob *next;
} IllucetPythonJob;

struct IllucetPythonEngine {
    char *python_home;
    char *bundled_app_path;
    char *bundled_packages_path;
    char *writable_packages_path;
    IllucetPythonEventCallback event_callback;
    void *event_context;

    pthread_t worker;
    pthread_mutex_t mutex;
    pthread_cond_t queue_condition;
    pthread_cond_t startup_condition;
    pthread_cond_t shutdown_condition;
    IllucetPythonJob *queue_head;
    IllucetPythonJob *queue_tail;
    IllucetPythonJob *current_job;

    bool thread_created;
    bool join_in_progress;
    bool worker_joined;
    bool startup_finished;
    bool interpreter_ready;
    bool stopping;
    bool stopped;
    int32_t startup_result;
    char *startup_error;
    int32_t shutdown_result;
    char *shutdown_error;
};

static _Thread_local IllucetPythonEngine *illucet_current_engine = NULL;
static _Thread_local IllucetPythonJob *illucet_current_job = NULL;
static pthread_once_t illucet_python_inittab_once = PTHREAD_ONCE_INIT;
static int illucet_python_inittab_result = -1;
PyMODINIT_FUNC PyInit__illucet_native(void);

static void illucet_register_builtin_modules(void) {
    illucet_python_inittab_result = PyImport_AppendInittab(
        "_illucet_native",
        PyInit__illucet_native
    );
}

static char *illucet_copy_string(const char *source) {
    if (source == NULL) {
        return NULL;
    }
    size_t length = strlen(source);
    char *copy = malloc(length + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, source, length + 1);
    return copy;
}

static void illucet_assign_error(char **destination, const char *message) {
    if (destination != NULL) {
        *destination = illucet_copy_string(message == NULL ? "Unknown error" : message);
    }
}

static bool illucet_contains_ascii_case_insensitive(
    const char *value,
    const char *marker
) {
    if (value == NULL || marker == NULL || marker[0] == '\0') {
        return false;
    }

    size_t marker_length = strlen(marker);
    for (const char *candidate = value;
         *candidate != '\0';
         candidate += 1) {
        size_t index = 0;
        while (index < marker_length &&
               candidate[index] != '\0' &&
               tolower((unsigned char)candidate[index]) ==
                   tolower((unsigned char)marker[index])) {
            index += 1;
        }
        if (index == marker_length) {
            return true;
        }
    }
    return false;
}

static bool illucet_contains_sensitive_error_detail(const char *value) {
    static const char *sensitive_markers[] = {
        "http://",
        "https://",
        "cookie",
        "authorization",
        "bearer ",
        "signature",
        "token",
        "sig=",
        "lsig=",
        "sparams=",
        "expire=",
        "oauth",
        "sessionid",
        "sapisid"
    };
    for (size_t index = 0;
         index < sizeof(sensitive_markers) / sizeof(sensitive_markers[0]);
         index += 1) {
        if (illucet_contains_ascii_case_insensitive(
                value,
                sensitive_markers[index]
            )) {
            return true;
        }
    }
    return false;
}

static PyObject *illucet_native_emit_json(PyObject *self, PyObject *args) {
    (void)self;
    const char *json = NULL;
    Py_ssize_t length = 0;
    if (!PyArg_ParseTuple(args, "s#:emit_json", &json, &length)) {
        return NULL;
    }
    if (length < 0 || (size_t)length > ILLUCET_PYTHON_MAX_EVENT_SIZE) {
        PyErr_SetString(
            PyExc_ValueError,
            "Native bridge event exceeds its size limit."
        );
        return NULL;
    }

    if (illucet_current_engine != NULL &&
        illucet_current_job != NULL &&
        illucet_current_engine->event_callback != NULL) {
        illucet_current_engine->event_callback(
            illucet_current_engine->event_context,
            illucet_current_job->request_id,
            json,
            (size_t)length
        );
    }

    Py_RETURN_NONE;
}

static PyObject *illucet_native_is_cancelled(PyObject *self, PyObject *args) {
    (void)self;
    (void)args;
    bool cancelled = illucet_current_job != NULL &&
        atomic_load_explicit(&illucet_current_job->cancelled, memory_order_relaxed);
    return PyBool_FromLong(cancelled ? 1 : 0);
}

static PyObject *illucet_native_is_main_thread(PyObject *self, PyObject *args) {
    (void)self;
    (void)args;
    return PyBool_FromLong(pthread_main_np() != 0 ? 1 : 0);
}

static bool illucet_quickjs_is_cancelled(void *context) {
    IllucetPythonJob *job = context;
    return job != NULL &&
        atomic_load_explicit(&job->cancelled, memory_order_relaxed);
}

static PyObject *illucet_native_quickjs_version(
    PyObject *self,
    PyObject *args
) {
    (void)self;
    (void)args;
    return PyUnicode_FromString(illucet_quickjs_version());
}

static PyObject *illucet_native_quickjs_evaluate(
    PyObject *self,
    PyObject *args
) {
    (void)self;

    const char *source = NULL;
    Py_ssize_t source_length = 0;
    unsigned long long memory_limit = 128ULL * 1024ULL * 1024ULL;
    unsigned long long stack_limit = 2ULL * 1024ULL * 1024ULL;
    unsigned int timeout_milliseconds = 30000;
    unsigned long long output_limit = 8ULL * 1024ULL * 1024ULL;
    if (!PyArg_ParseTuple(
            args,
            "s#|KKIK:quickjs_evaluate",
            &source,
            &source_length,
            &memory_limit,
            &stack_limit,
            &timeout_milliseconds,
            &output_limit
        )) {
        return NULL;
    }

    const unsigned long long minimum_memory = 16ULL * 1024ULL * 1024ULL;
    const unsigned long long maximum_memory = 256ULL * 1024ULL * 1024ULL;
    const unsigned long long minimum_stack = 256ULL * 1024ULL;
    const unsigned long long maximum_stack = 4ULL * 1024ULL * 1024ULL;
    const unsigned long long maximum_output = 16ULL * 1024ULL * 1024ULL;
    const Py_ssize_t maximum_source_length = 16 * 1024 * 1024;
    if (source_length <= 0 ||
        source_length > maximum_source_length ||
        memory_limit < minimum_memory ||
        memory_limit > maximum_memory ||
        stack_limit < minimum_stack ||
        stack_limit > maximum_stack ||
        timeout_milliseconds == 0 ||
        timeout_milliseconds > 60000 ||
        output_limit == 0 ||
        output_limit > maximum_output) {
        PyErr_SetString(
            PyExc_ValueError,
            "QuickJS resource limits are outside Illucet's safe bounds."
        );
        return NULL;
    }

    char *output = NULL;
    size_t output_length = 0;
    char *error_message = NULL;
    int32_t result = illucet_quickjs_evaluate(
        source,
        (size_t)source_length,
        (size_t)memory_limit,
        (size_t)stack_limit,
        timeout_milliseconds,
        (size_t)output_limit,
        illucet_quickjs_is_cancelled,
        illucet_current_job,
        &output,
        &output_length,
        &error_message
    );

    if (result != ILLUCET_QUICKJS_OK) {
        PyObject *exception = PyExc_RuntimeError;
        if (result == ILLUCET_QUICKJS_TIMEOUT) {
            exception = PyExc_TimeoutError;
        } else if (result == ILLUCET_QUICKJS_CANCELLED) {
            exception = PyExc_InterruptedError;
        } else if (result == ILLUCET_QUICKJS_OUTPUT_LIMIT) {
            exception = PyExc_OverflowError;
        }
        PyErr_SetString(
            exception,
            error_message == NULL
                ? "Unknown in-process QuickJS error."
                : error_message
        );
        illucet_quickjs_string_free(output);
        illucet_quickjs_string_free(error_message);
        return NULL;
    }

    PyObject *python_output = PyUnicode_FromStringAndSize(
        output == NULL ? "" : output,
        (Py_ssize_t)output_length
    );
    illucet_quickjs_string_free(output);
    illucet_quickjs_string_free(error_message);
    return python_output;
}

static PyMethodDef illucet_native_methods[] = {
    {
        "emit_json",
        illucet_native_emit_json,
        METH_VARARGS,
        "Emit one UTF-8 JSON event through the native callback."
    },
    {
        "is_cancelled",
        illucet_native_is_cancelled,
        METH_NOARGS,
        "Return whether Swift cancelled the current request."
    },
    {
        "is_main_thread",
        illucet_native_is_main_thread,
        METH_NOARGS,
        "Return whether Python is executing on the process main thread."
    },
    {
        "quickjs_version",
        illucet_native_quickjs_version,
        METH_NOARGS,
        "Return the statically linked QuickJS-ng version."
    },
    {
        "quickjs_evaluate",
        illucet_native_quickjs_evaluate,
        METH_VARARGS,
        "Evaluate JavaScript in-process with bounded resources."
    },
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef illucet_native_module = {
    PyModuleDef_HEAD_INIT,
    "_illucet_native",
    "Narrow native services exposed to Illucet Python code.",
    -1,
    illucet_native_methods,
    NULL,
    NULL,
    NULL,
    NULL
};

PyMODINIT_FUNC PyInit__illucet_native(void) {
    return PyModule_Create(&illucet_native_module);
}

static int illucet_audit_hook(
    const char *event,
    PyObject *arguments,
    void *user_data
) {
    (void)arguments;
    (void)user_data;

    static const char *blocked_events[] = {
        "os.exec",
        "os.fork",
        "os.forkpty",
        "os.system",
        "os.spawn",
        "os.posix_spawn",
        "pty.spawn",
        "subprocess.Popen"
    };

    for (size_t index = 0;
         index < sizeof(blocked_events) / sizeof(blocked_events[0]);
         index += 1) {
        size_t prefix_length = strlen(blocked_events[index]);
        if (strncmp(event, blocked_events[index], prefix_length) == 0) {
            PyErr_Format(
                PyExc_RuntimeError,
                "Illucet blocked forbidden child-process audit event: %s",
                event
            );
            return -1;
        }
    }

    return 0;
}

static bool illucet_append_python_path(const char *path, char **error_message) {
    PyObject *sys_path = PySys_GetObject("path");
    if (sys_path == NULL || !PyList_Check(sys_path)) {
        illucet_assign_error(error_message, "Python sys.path is unavailable.");
        return false;
    }

    PyObject *python_path = PyUnicode_FromString(path);
    if (python_path == NULL) {
        illucet_assign_error(error_message, "Could not encode a Python import path.");
        PyErr_Clear();
        return false;
    }

    int result = PyList_Append(sys_path, python_path);
    Py_DECREF(python_path);
    if (result != 0) {
        illucet_assign_error(error_message, "Could not append a Python import path.");
        PyErr_Clear();
        return false;
    }
    return true;
}

static char *illucet_python_exception_message(void) {
    PyObject *exception_type = NULL;
    PyObject *exception_value = NULL;
    PyObject *exception_traceback = NULL;
    PyErr_Fetch(&exception_type, &exception_value, &exception_traceback);
    PyErr_NormalizeException(
        &exception_type,
        &exception_value,
        &exception_traceback
    );

    const char *type_name = "PythonError";
    PyObject *name = NULL;
    if (exception_type != NULL) {
        name = PyObject_GetAttrString(exception_type, "__name__");
        if (name != NULL && PyUnicode_Check(name)) {
            const char *candidate = PyUnicode_AsUTF8(name);
            if (candidate != NULL) {
                type_name = candidate;
            }
        }
    }

    const char *value_text = "";
    PyObject *value_string = NULL;
    if (exception_value != NULL) {
        value_string = PyObject_Str(exception_value);
        if (value_string != NULL) {
            const char *candidate = PyUnicode_AsUTF8(value_string);
            if (candidate != NULL) {
                value_text = candidate;
            }
        }
    }

    if (illucet_contains_sensitive_error_detail(value_text)) {
        value_text = "[redacted sensitive error detail]";
    }

    const size_t maximum_value_length = 2048;
    size_t value_length = strlen(value_text);
    if (value_length > maximum_value_length) {
        value_length = maximum_value_length;
    }
    size_t needed = strlen(type_name) + value_length + 3;
    char *message = malloc(needed);
    if (message != NULL) {
        snprintf(
            message,
            needed,
            "%s: %.*s",
            type_name,
            (int)value_length,
            value_text
        );
    }

    Py_XDECREF(value_string);
    Py_XDECREF(name);
    Py_XDECREF(exception_type);
    Py_XDECREF(exception_value);
    Py_XDECREF(exception_traceback);
    PyErr_Clear();

    return message == NULL
        ? illucet_copy_string("PythonError: unable to allocate error message")
        : message;
}

static int32_t illucet_initialize_interpreter(
    IllucetPythonEngine *engine,
    char **error_message
) {
    if (pthread_once(
            &illucet_python_inittab_once,
            illucet_register_builtin_modules
        ) != 0 || illucet_python_inittab_result == -1) {
        illucet_assign_error(
            error_message,
            "PyImport_AppendInittab rejected _illucet_native."
        );
        return ILLUCET_PYTHON_ERROR;
    }

    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;

    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        illucet_assign_error(error_message, status.err_msg);
        return ILLUCET_PYTHON_ERROR;
    }

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    config.install_signal_handlers = 0;
    config.parse_argv = 0;
    config.site_import = 0;
    config.use_environment = 0;
    config.use_system_logger = 1;
    config.user_site_directory = 0;
    config.write_bytecode = 0;

    status = PyConfig_SetBytesString(
        &config,
        &config.home,
        engine->python_home
    );
    if (!PyStatus_Exception(status)) {
        status = Py_InitializeFromConfig(&config);
    }
    PyConfig_Clear(&config);

    if (PyStatus_Exception(status)) {
        illucet_assign_error(error_message, status.err_msg);
        return ILLUCET_PYTHON_ERROR;
    }

    if (PySys_AddAuditHook(illucet_audit_hook, NULL) != 0) {
        illucet_assign_error(error_message, "Could not install the Python audit hook.");
        PyErr_Clear();
        return ILLUCET_PYTHON_ERROR;
    }

    if (!illucet_append_python_path(engine->bundled_app_path, error_message) ||
        !illucet_append_python_path(engine->writable_packages_path, error_message) ||
        !illucet_append_python_path(engine->bundled_packages_path, error_message)) {
        return ILLUCET_PYTHON_ERROR;
    }

    PyObject *package_root = PyUnicode_FromString(engine->writable_packages_path);
    if (package_root == NULL || PySys_SetObject("_illucet_package_root", package_root) != 0) {
        Py_XDECREF(package_root);
        illucet_assign_error(error_message, "Could not set the verified package root.");
        PyErr_Clear();
        return ILLUCET_PYTHON_ERROR;
    }
    Py_DECREF(package_root);

    PyObject *provider = PyImport_ImportModule("illucet_ytdlp_provider");
    if (provider == NULL) {
        char *provider_error = illucet_python_exception_message();
        illucet_assign_error(
            error_message,
            provider_error == NULL
                ? "Could not register Illucet's JavaScript provider."
                : provider_error
        );
        free(provider_error);
        return ILLUCET_PYTHON_ERROR;
    }
    Py_DECREF(provider);

    return ILLUCET_PYTHON_OK;
}

static void illucet_process_job(IllucetPythonJob *job) {
    illucet_current_job = job;

    PyObject *module = PyImport_ImportModule("illucet_bridge");
    if (module == NULL) {
        job->error_message = illucet_python_exception_message();
        job->result = ILLUCET_PYTHON_ERROR;
        illucet_current_job = NULL;
        return;
    }

    PyObject *function = PyObject_GetAttrString(module, "handle_request");
    if (function == NULL) {
        Py_DECREF(module);
        job->error_message = illucet_python_exception_message();
        job->result = ILLUCET_PYTHON_ERROR;
        illucet_current_job = NULL;
        return;
    }
    if (!PyCallable_Check(function)) {
        Py_DECREF(function);
        Py_DECREF(module);
        PyErr_Clear();
        job->error_message = illucet_copy_string(
            "Python module illucet_bridge has no callable handle_request."
        );
        job->result = ILLUCET_PYTHON_ERROR;
        illucet_current_job = NULL;
        return;
    }

    PyObject *argument = PyUnicode_FromString(job->request_json);
    PyObject *result = argument == NULL
        ? NULL
        : PyObject_CallOneArg(function, argument);

    if (result == NULL) {
        job->error_message = illucet_python_exception_message();
        job->result = atomic_load_explicit(
            &job->cancelled,
            memory_order_relaxed
        ) ? ILLUCET_PYTHON_CANCELLED : ILLUCET_PYTHON_ERROR;
    } else if (!PyUnicode_Check(result)) {
        job->error_message = illucet_copy_string(
            "Python handle_request must return a JSON string."
        );
        job->result = ILLUCET_PYTHON_ERROR;
    } else {
        Py_ssize_t length = 0;
        const char *utf8 = PyUnicode_AsUTF8AndSize(result, &length);
        if (utf8 == NULL) {
            job->error_message = illucet_python_exception_message();
            job->result = ILLUCET_PYTHON_ERROR;
        } else if (
            length < 0 ||
            (size_t)length > ILLUCET_PYTHON_MAX_RESPONSE_SIZE
        ) {
            job->error_message = illucet_copy_string(
                "Python response exceeds the native bridge size limit."
            );
            job->result = ILLUCET_PYTHON_ERROR;
        } else {
            job->response_json = malloc((size_t)length + 1);
            if (job->response_json == NULL) {
                job->error_message = illucet_copy_string(
                    "Could not allocate the Python response."
                );
                job->result = ILLUCET_PYTHON_ERROR;
            } else {
                memcpy(job->response_json, utf8, (size_t)length);
                job->response_json[length] = '\0';
                job->result = ILLUCET_PYTHON_OK;
            }
        }
    }

    Py_XDECREF(result);
    Py_XDECREF(argument);
    Py_DECREF(function);
    Py_DECREF(module);
    illucet_current_job = NULL;
}

static void *illucet_python_worker(void *opaque_engine) {
    IllucetPythonEngine *engine = opaque_engine;
    illucet_current_engine = engine;

    char *startup_error = NULL;
    int32_t startup_result = illucet_initialize_interpreter(
        engine,
        &startup_error
    );

    pthread_mutex_lock(&engine->mutex);
    engine->startup_result = startup_result;
    engine->startup_error = startup_error;
    engine->interpreter_ready = startup_result == ILLUCET_PYTHON_OK;
    engine->startup_finished = true;
    pthread_cond_broadcast(&engine->startup_condition);
    pthread_mutex_unlock(&engine->mutex);

    if (startup_result != ILLUCET_PYTHON_OK) {
        int finalize_result = 0;
        if (Py_IsInitialized()) {
            finalize_result = Py_FinalizeEx();
        }
        pthread_mutex_lock(&engine->mutex);
        engine->interpreter_ready = false;
        engine->stopped = true;
        if (finalize_result != 0) {
            engine->shutdown_result = ILLUCET_PYTHON_ERROR;
            engine->shutdown_error = illucet_copy_string(
                "Py_FinalizeEx failed after Python startup failed."
            );
        }
        pthread_cond_broadcast(&engine->shutdown_condition);
        pthread_mutex_unlock(&engine->mutex);
        illucet_current_engine = NULL;
        return NULL;
    }

    while (true) {
        pthread_mutex_lock(&engine->mutex);
        while (engine->queue_head == NULL && !engine->stopping) {
            pthread_cond_wait(&engine->queue_condition, &engine->mutex);
        }

        if (engine->queue_head == NULL && engine->stopping) {
            pthread_mutex_unlock(&engine->mutex);
            break;
        }

        IllucetPythonJob *job = engine->queue_head;
        engine->queue_head = job->next;
        if (engine->queue_head == NULL) {
            engine->queue_tail = NULL;
        }
        engine->current_job = job;
        pthread_mutex_unlock(&engine->mutex);

        if (atomic_load_explicit(
                &job->cancelled,
                memory_order_relaxed
            )) {
            job->error_message = illucet_copy_string(
                "The queued Python request was cancelled before execution."
            );
            job->result = ILLUCET_PYTHON_CANCELLED;
        } else {
            illucet_process_job(job);
        }

        pthread_mutex_lock(&engine->mutex);
        engine->current_job = NULL;
        job->finished = true;
        pthread_cond_signal(&job->completion_condition);
        pthread_mutex_unlock(&engine->mutex);
    }

    int finalize_result = Py_FinalizeEx();

    pthread_mutex_lock(&engine->mutex);
    engine->interpreter_ready = false;
    engine->stopped = true;
    if (finalize_result != 0 && engine->startup_error == NULL) {
        engine->shutdown_result = ILLUCET_PYTHON_ERROR;
        engine->shutdown_error = illucet_copy_string(
            "Py_FinalizeEx reported an unhandled shutdown error."
        );
    }
    pthread_cond_broadcast(&engine->shutdown_condition);
    pthread_mutex_unlock(&engine->mutex);

    illucet_current_engine = NULL;
    return NULL;
}

IllucetPythonEngine *illucet_python_engine_create(
    const char *python_home,
    const char *bundled_app_path,
    const char *bundled_packages_path,
    const char *writable_packages_path,
    IllucetPythonEventCallback event_callback,
    void *event_context
) {
    if (python_home == NULL ||
        bundled_app_path == NULL ||
        bundled_packages_path == NULL ||
        writable_packages_path == NULL) {
        return NULL;
    }

    IllucetPythonEngine *engine = calloc(1, sizeof(IllucetPythonEngine));
    if (engine == NULL) {
        return NULL;
    }

    engine->python_home = illucet_copy_string(python_home);
    engine->bundled_app_path = illucet_copy_string(bundled_app_path);
    engine->bundled_packages_path = illucet_copy_string(bundled_packages_path);
    engine->writable_packages_path = illucet_copy_string(writable_packages_path);
    engine->event_callback = event_callback;
    engine->event_context = event_context;

    if (engine->python_home == NULL ||
        engine->bundled_app_path == NULL ||
        engine->bundled_packages_path == NULL ||
        engine->writable_packages_path == NULL) {
        free(engine->python_home);
        free(engine->bundled_app_path);
        free(engine->bundled_packages_path);
        free(engine->writable_packages_path);
        free(engine);
        return NULL;
    }

    if (pthread_mutex_init(&engine->mutex, NULL) != 0) {
        free(engine->python_home);
        free(engine->bundled_app_path);
        free(engine->bundled_packages_path);
        free(engine->writable_packages_path);
        free(engine);
        return NULL;
    }
    if (pthread_cond_init(&engine->queue_condition, NULL) != 0) {
        pthread_mutex_destroy(&engine->mutex);
        free(engine->python_home);
        free(engine->bundled_app_path);
        free(engine->bundled_packages_path);
        free(engine->writable_packages_path);
        free(engine);
        return NULL;
    }
    if (pthread_cond_init(&engine->startup_condition, NULL) != 0) {
        pthread_cond_destroy(&engine->queue_condition);
        pthread_mutex_destroy(&engine->mutex);
        free(engine->python_home);
        free(engine->bundled_app_path);
        free(engine->bundled_packages_path);
        free(engine->writable_packages_path);
        free(engine);
        return NULL;
    }
    if (pthread_cond_init(&engine->shutdown_condition, NULL) != 0) {
        pthread_cond_destroy(&engine->startup_condition);
        pthread_cond_destroy(&engine->queue_condition);
        pthread_mutex_destroy(&engine->mutex);
        free(engine->python_home);
        free(engine->bundled_app_path);
        free(engine->bundled_packages_path);
        free(engine->writable_packages_path);
        free(engine);
        return NULL;
    }

    return engine;
}

int32_t illucet_python_engine_start(
    IllucetPythonEngine *engine,
    char **error_message
) {
    if (error_message != NULL) {
        *error_message = NULL;
    }
    if (engine == NULL) {
        illucet_assign_error(error_message, "Python engine is null.");
        return ILLUCET_PYTHON_ERROR;
    }

    pthread_mutex_lock(&engine->mutex);
    if (engine->worker_joined ||
        engine->join_in_progress ||
        engine->stopping ||
        (engine->stopped && engine->startup_result == ILLUCET_PYTHON_OK)) {
        pthread_mutex_unlock(&engine->mutex);
        illucet_assign_error(
            error_message,
            "Python engine has reached a terminal state."
        );
        return ILLUCET_PYTHON_NOT_RUNNING;
    }
    if (!engine->thread_created) {
        pthread_attr_t attributes;
        int attribute_result = pthread_attr_init(&attributes);
        if (attribute_result != 0) {
            pthread_mutex_unlock(&engine->mutex);
            illucet_assign_error(
                error_message,
                "pthread_attr_init failed for the Python worker."
            );
            return ILLUCET_PYTHON_ERROR;
        }
        attribute_result = pthread_attr_setstacksize(
            &attributes,
            ILLUCET_PYTHON_WORKER_STACK_SIZE
        );
        if (attribute_result != 0) {
            pthread_attr_destroy(&attributes);
            pthread_mutex_unlock(&engine->mutex);
            illucet_assign_error(
                error_message,
                "Could not reserve the bounded Python worker stack."
            );
            return ILLUCET_PYTHON_ERROR;
        }
        int result = pthread_create(
            &engine->worker,
            &attributes,
            illucet_python_worker,
            engine
        );
        pthread_attr_destroy(&attributes);
        if (result != 0) {
            pthread_mutex_unlock(&engine->mutex);
            illucet_assign_error(
                error_message,
                "pthread_create failed for the Python worker."
            );
            return ILLUCET_PYTHON_ERROR;
        }
        engine->thread_created = true;
    }

    while (!engine->startup_finished) {
        pthread_cond_wait(&engine->startup_condition, &engine->mutex);
    }

    int32_t result = engine->startup_result;
    if (result != ILLUCET_PYTHON_OK) {
        illucet_assign_error(error_message, engine->startup_error);
    } else if (!engine->interpreter_ready || engine->stopping) {
        result = ILLUCET_PYTHON_NOT_RUNNING;
        illucet_assign_error(
            error_message,
            "Python engine stopped during startup."
        );
    }
    pthread_mutex_unlock(&engine->mutex);
    return result;
}

int32_t illucet_python_engine_execute(
    IllucetPythonEngine *engine,
    uint64_t request_id,
    const char *request_json,
    char **response_json,
    char **error_message
) {
    if (response_json != NULL) {
        *response_json = NULL;
    }
    if (error_message != NULL) {
        *error_message = NULL;
    }
    if (engine == NULL || request_json == NULL) {
        illucet_assign_error(error_message, "Python request is invalid.");
        return ILLUCET_PYTHON_ERROR;
    }
    if (
        strnlen(request_json, ILLUCET_PYTHON_MAX_REQUEST_SIZE + 1) >
        ILLUCET_PYTHON_MAX_REQUEST_SIZE
    ) {
        illucet_assign_error(
            error_message,
            "Python request exceeds the native bridge size limit."
        );
        return ILLUCET_PYTHON_ERROR;
    }

    IllucetPythonJob *job = calloc(1, sizeof(IllucetPythonJob));
    if (job == NULL) {
        illucet_assign_error(error_message, "Could not allocate a Python job.");
        return ILLUCET_PYTHON_ERROR;
    }
    job->request_id = request_id;
    job->request_json = illucet_copy_string(request_json);
    atomic_init(&job->cancelled, false);

    if (job->request_json == NULL) {
        free(job);
        illucet_assign_error(error_message, "Could not copy a Python request.");
        return ILLUCET_PYTHON_ERROR;
    }
    if (pthread_cond_init(&job->completion_condition, NULL) != 0) {
        free(job->request_json);
        free(job);
        illucet_assign_error(
            error_message,
            "Could not initialize Python job synchronization."
        );
        return ILLUCET_PYTHON_ERROR;
    }

    pthread_mutex_lock(&engine->mutex);
    if (!engine->interpreter_ready || engine->stopping) {
        pthread_mutex_unlock(&engine->mutex);
        pthread_cond_destroy(&job->completion_condition);
        free(job->request_json);
        free(job);
        illucet_assign_error(error_message, "Python engine is not running.");
        return ILLUCET_PYTHON_NOT_RUNNING;
    }

    if (engine->queue_tail == NULL) {
        engine->queue_head = job;
        engine->queue_tail = job;
    } else {
        engine->queue_tail->next = job;
        engine->queue_tail = job;
    }
    pthread_cond_signal(&engine->queue_condition);

    while (!job->finished) {
        pthread_cond_wait(&job->completion_condition, &engine->mutex);
    }
    pthread_mutex_unlock(&engine->mutex);

    int32_t result = job->result;
    if (response_json != NULL) {
        *response_json = job->response_json;
        job->response_json = NULL;
    }
    if (error_message != NULL) {
        *error_message = job->error_message;
        job->error_message = NULL;
    }

    pthread_cond_destroy(&job->completion_condition);
    free(job->request_json);
    free(job->response_json);
    free(job->error_message);
    free(job);
    return result;
}

void illucet_python_engine_cancel(
    IllucetPythonEngine *engine,
    uint64_t request_id
) {
    if (engine == NULL) {
        return;
    }

    pthread_mutex_lock(&engine->mutex);
    if (engine->current_job != NULL &&
        engine->current_job->request_id == request_id) {
        atomic_store_explicit(
            &engine->current_job->cancelled,
            true,
            memory_order_relaxed
        );
    }
    for (IllucetPythonJob *job = engine->queue_head;
         job != NULL;
         job = job->next) {
        if (job->request_id == request_id) {
            atomic_store_explicit(
                &job->cancelled,
                true,
                memory_order_relaxed
            );
            break;
        }
    }
    pthread_mutex_unlock(&engine->mutex);
}

int32_t illucet_python_engine_shutdown(
    IllucetPythonEngine *engine,
    char **error_message
) {
    if (error_message != NULL) {
        *error_message = NULL;
    }
    if (engine == NULL) {
        return ILLUCET_PYTHON_OK;
    }

    pthread_mutex_lock(&engine->mutex);
    if (!engine->thread_created) {
        engine->stopped = true;
        pthread_mutex_unlock(&engine->mutex);
        return ILLUCET_PYTHON_OK;
    }

    while (engine->join_in_progress) {
        pthread_cond_wait(
            &engine->shutdown_condition,
            &engine->mutex
        );
    }
    if (engine->worker_joined) {
        int32_t result = engine->shutdown_result;
        if (result != ILLUCET_PYTHON_OK) {
            illucet_assign_error(error_message, engine->shutdown_error);
        }
        pthread_mutex_unlock(&engine->mutex);
        return result;
    }

    engine->join_in_progress = true;
    engine->stopping = true;
    if (engine->current_job != NULL) {
        atomic_store_explicit(
            &engine->current_job->cancelled,
            true,
            memory_order_relaxed
        );
    }
    for (IllucetPythonJob *job = engine->queue_head;
         job != NULL;
         job = job->next) {
        atomic_store_explicit(
            &job->cancelled,
            true,
            memory_order_relaxed
        );
    }
    pthread_cond_broadcast(&engine->queue_condition);
    pthread_mutex_unlock(&engine->mutex);

    int join_result = pthread_join(engine->worker, NULL);

    pthread_mutex_lock(&engine->mutex);
    engine->join_in_progress = false;
    if (join_result == 0) {
        engine->worker_joined = true;
    } else {
        engine->shutdown_result = ILLUCET_PYTHON_ERROR;
        free(engine->shutdown_error);
        engine->shutdown_error = illucet_copy_string(
            "pthread_join failed for the Python worker."
        );
    }
    pthread_cond_broadcast(&engine->shutdown_condition);
    int32_t result = engine->shutdown_result;
    if (result != ILLUCET_PYTHON_OK) {
        illucet_assign_error(error_message, engine->shutdown_error);
    }
    pthread_mutex_unlock(&engine->mutex);
    return result;
}

void illucet_python_engine_destroy(IllucetPythonEngine *engine) {
    if (engine == NULL) {
        return;
    }

    if (engine->thread_created && !engine->worker_joined) {
        illucet_python_engine_shutdown(engine, NULL);
        pthread_mutex_lock(&engine->mutex);
        bool safe_to_destroy = engine->worker_joined;
        pthread_mutex_unlock(&engine->mutex);
        if (!safe_to_destroy) {
            return;
        }
    }

    pthread_cond_destroy(&engine->shutdown_condition);
    pthread_cond_destroy(&engine->startup_condition);
    pthread_cond_destroy(&engine->queue_condition);
    pthread_mutex_destroy(&engine->mutex);
    free(engine->python_home);
    free(engine->bundled_app_path);
    free(engine->bundled_packages_path);
    free(engine->writable_packages_path);
    free(engine->startup_error);
    free(engine->shutdown_error);
    free(engine);
}

void illucet_python_string_free(char *value) {
    free(value);
}
