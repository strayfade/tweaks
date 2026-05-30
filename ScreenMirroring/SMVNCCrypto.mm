#import "SMVNCCrypto.h"
#import <CommonCrypto/CommonCrypto.h>

void smVNCPrepareDESKey(unsigned char *key, const char *password) {
    for (int index = 0; index < 8; index++) {
        unsigned char byte = (password && index < (int)strlen(password)) ? (unsigned char)password[index] : 0;
        unsigned char reversed = 0;
        for (int bit = 0; bit < 8; bit++) {
            if (byte & (1 << bit)) {
                reversed |= (1 << (7 - bit));
            }
        }
        key[index] = reversed;
    }
}

void smVNCEncryptChallenge(unsigned char *response, const unsigned char *challenge, const char *password) {
    unsigned char key[8];
    smVNCPrepareDESKey(key, password);

    size_t moved = 0;
    CCCryptorStatus status = CCCrypt(kCCEncrypt,
                                     kCCAlgorithmDES,
                                     kCCOptionECBMode,
                                     key,
                                     kCCKeySizeDES,
                                     NULL,
                                     challenge,
                                     8,
                                     response,
                                     8,
                                     &moved);
    if (status != kCCSuccess) {
        memset(response, 0, 8);
        return;
    }

    status = CCCrypt(kCCEncrypt,
                     kCCAlgorithmDES,
                     kCCOptionECBMode,
                     key,
                     kCCKeySizeDES,
                     NULL,
                     challenge + 8,
                     8,
                     response + 8,
                     8,
                     &moved);
    if (status != kCCSuccess) {
        memset(response + 8, 0, 8);
    }
}
