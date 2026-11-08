#include "IllucetHostResolver.h"

#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>

#define ILLUCET_MAX_RESOLVED_ADDRESSES 32

static int illucet_append_unique_address(
    const char *numeric,
    char *output,
    size_t output_capacity,
    size_t *address_count,
    size_t *used
) {
    int duplicate = 0;
    const char *cursor = output;
    while (*cursor != '\0') {
        const char *end = strchr(cursor, '\n');
        size_t length = end == NULL
            ? strlen(cursor)
            : (size_t)(end - cursor);
        if (strlen(numeric) == length &&
            strncmp(cursor, numeric, length) == 0) {
            duplicate = 1;
            break;
        }
        if (end == NULL) {
            break;
        }
        cursor = end + 1;
    }
    if (duplicate) {
        return 0;
    }
    if (*address_count >= ILLUCET_MAX_RESOLVED_ADDRESSES) {
        return -4;
    }

    size_t length = strlen(numeric);
    size_t needed = length + (*used == 0 ? 0 : 1) + 1;
    if (needed > output_capacity - *used) {
        return -3;
    }
    if (*used != 0) {
        output[(*used)++] = '\n';
    }
    memcpy(output + *used, numeric, length);
    *used += length;
    output[*used] = '\0';
    *address_count += 1;
    return 0;
}

static int illucet_finish_resolution(
    int status,
    char *output,
    size_t *address_count
) {
    if (status == 0 && *address_count > 0) {
        return 0;
    }
    output[0] = '\0';
    *address_count = 0;
    return status == 0 ? -2 : status;
}

int illucet_resolve_host(
    const char *host,
    char *output,
    size_t output_capacity,
    size_t *address_count
) {
    if (host == NULL || host[0] == '\0' || output == NULL ||
        output_capacity < 2 || address_count == NULL) {
        return -1;
    }

    *address_count = 0;
    output[0] = '\0';
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    hints.ai_flags = AI_ADDRCONFIG;

    struct addrinfo *results = NULL;
    if (getaddrinfo(host, NULL, &hints, &results) != 0 || results == NULL) {
        return -2;
    }

    size_t used = 0;
    int status = 0;
    for (struct addrinfo *entry = results;
         entry != NULL;
         entry = entry->ai_next) {
        char numeric[NI_MAXHOST];
        if (getnameinfo(
                entry->ai_addr,
                entry->ai_addrlen,
                numeric,
                sizeof(numeric),
                NULL,
                0,
                NI_NUMERICHOST
            ) != 0) {
            status = -2;
            break;
        }
        status = illucet_append_unique_address(
            numeric,
            output,
            output_capacity,
            address_count,
            &used
        );
        if (status != 0) {
            break;
        }
    }

    freeaddrinfo(results);
    return illucet_finish_resolution(status, output, address_count);
}

#if DEBUG
int illucet_test_inspect_numeric_answer_chain(
    const char *answer_chain,
    char *output,
    size_t output_capacity,
    size_t *address_count
) {
    if (answer_chain == NULL || answer_chain[0] == '\0' || output == NULL ||
        output_capacity < 2 || address_count == NULL) {
        return -1;
    }

    *address_count = 0;
    output[0] = '\0';
    size_t used = 0;
    int status = 0;
    const char *cursor = answer_chain;
    while (*cursor != '\0') {
        const char *end = strchr(cursor, '\n');
        size_t length = end == NULL
            ? strlen(cursor)
            : (size_t)(end - cursor);
        if (length == 0 || length >= NI_MAXHOST) {
            status = -1;
            break;
        }
        char numeric[NI_MAXHOST];
        memcpy(numeric, cursor, length);
        numeric[length] = '\0';
        status = illucet_append_unique_address(
            numeric,
            output,
            output_capacity,
            address_count,
            &used
        );
        if (status != 0) {
            break;
        }
        if (end == NULL) {
            break;
        }
        cursor = end + 1;
    }
    if (*cursor == '\0' && cursor != answer_chain && cursor[-1] == '\n') {
        status = -1;
    }
    return illucet_finish_resolution(status, output, address_count);
}
#endif
