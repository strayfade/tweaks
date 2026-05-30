#import <Foundation/Foundation.h>

void smVNCPrepareDESKey(unsigned char *key, const char *password);
void smVNCEncryptChallenge(unsigned char *response, const unsigned char *challenge, const char *password);
