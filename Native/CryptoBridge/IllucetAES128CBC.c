#include "IllucetAES128CBC.h"

#include <CommonCrypto/CommonCryptor.h>
#include <stdlib.h>

struct IllucetAES128CBCDecryptor {
    CCCryptorRef cryptor;
};

IllucetAES128CBCDecryptor *IllucetAES128CBCDecryptorCreate(
    const uint8_t *key,
    size_t keyLength,
    const uint8_t *initializationVector,
    size_t initializationVectorLength
) {
    if (key == NULL || keyLength != kCCKeySizeAES128
        || initializationVector == NULL
        || initializationVectorLength != kCCBlockSizeAES128) {
        return NULL;
    }

    IllucetAES128CBCDecryptor *decryptor = calloc(1, sizeof(*decryptor));
    if (decryptor == NULL) {
        return NULL;
    }
    CCCryptorStatus status = CCCryptorCreate(
        kCCDecrypt,
        kCCAlgorithmAES,
        0,
        key,
        keyLength,
        initializationVector,
        &decryptor->cryptor
    );
    if (status != kCCSuccess || decryptor->cryptor == NULL) {
        free(decryptor);
        return NULL;
    }
    return decryptor;
}

int32_t IllucetAES128CBCDecryptorUpdate(
    IllucetAES128CBCDecryptor *decryptor,
    const uint8_t *input,
    size_t inputLength,
    uint8_t *output,
    size_t outputCapacity,
    size_t *outputLength
) {
    if (decryptor == NULL || decryptor->cryptor == NULL
        || input == NULL || inputLength == 0 || output == NULL
        || outputLength == NULL) {
        return IllucetAES128CBCStatusInvalidInput;
    }
    *outputLength = 0;
    CCCryptorStatus status = CCCryptorUpdate(
        decryptor->cryptor,
        input,
        inputLength,
        output,
        outputCapacity,
        outputLength
    );
    return status == kCCSuccess
        ? IllucetAES128CBCStatusOK
        : IllucetAES128CBCStatusCryptorFailure;
}

int32_t IllucetAES128CBCDecryptorFinal(
    IllucetAES128CBCDecryptor *decryptor,
    uint8_t *output,
    size_t outputCapacity,
    size_t *outputLength
) {
    if (decryptor == NULL || decryptor->cryptor == NULL
        || output == NULL || outputLength == NULL) {
        return IllucetAES128CBCStatusInvalidInput;
    }
    *outputLength = 0;
    CCCryptorStatus status = CCCryptorFinal(
        decryptor->cryptor,
        output,
        outputCapacity,
        outputLength
    );
    return status == kCCSuccess
        ? IllucetAES128CBCStatusOK
        : IllucetAES128CBCStatusCryptorFailure;
}

void IllucetAES128CBCDecryptorDestroy(
    IllucetAES128CBCDecryptor *decryptor
) {
    if (decryptor == NULL) {
        return;
    }
    if (decryptor->cryptor != NULL) {
        CCCryptorRelease(decryptor->cryptor);
        decryptor->cryptor = NULL;
    }
    free(decryptor);
}
