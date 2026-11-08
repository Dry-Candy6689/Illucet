#ifndef ILLUCET_HOST_RESOLVER_H
#define ILLUCET_HOST_RESOLVER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Writes unique numeric IPv4/IPv6 addresses separated by newlines.
// Returns 0 on success and a negative value on invalid input, resolver
// failure, or bounded-buffer exhaustion.
int illucet_resolve_host(
    const char *host,
    char *output,
    size_t output_capacity,
    size_t *address_count
);

#if DEBUG
// Deterministic Debug-only seam for exercising the same bounded accumulator
// as the live addrinfo traversal without performing DNS.
int illucet_test_inspect_numeric_answer_chain(
    const char *answer_chain,
    char *output,
    size_t output_capacity,
    size_t *address_count
);
#endif

#ifdef __cplusplus
}
#endif

#endif
