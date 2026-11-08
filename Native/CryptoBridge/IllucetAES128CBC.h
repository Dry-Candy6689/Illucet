#ifndef ILLUCET_AES128_CBC_H
#define ILLUCET_AES128_CBC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IllucetAES128CBCDecryptor IllucetAES128CBCDecryptor;

enum {
    IllucetAES128CBCStatusOK = 0,
    IllucetAES128CBCStatusInvalidInput = 1,
    IllucetAES128CBCStatusCryptorFailure = 2,
};

IllucetAES128CBCDecryptor *IllucetAES128CBCDecryptorCreate(
    const uint8_t *key,
    size_t keyLength,
    const uint8_t *initializationVector,
    size_t initializationVectorLength
);

int32_t IllucetAES128CBCDecryptorUpdate(
    IllucetAES128CBCDecryptor *decryptor,
    const uint8_t *input,
    size_t inputLength,
    uint8_t *output,
    size_t outputCapacity,
    size_t *outputLength
);

int32_t IllucetAES128CBCDecryptorFinal(
    IllucetAES128CBCDecryptor *decryptor,
    uint8_t *output,
    size_t outputCapacity,
    size_t *outputLength
);

void IllucetAES128CBCDecryptorDestroy(
    IllucetAES128CBCDecryptor *decryptor
);

#ifdef __cplusplus
}
#endif

#endif
