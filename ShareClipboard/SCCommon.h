#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const kSCPrefsSuite = @"com.strayfade.shareclipboard~prefs";
static NSString *const kSCServiceType = @"_shareclipboard._tcp.";
static NSString *const kSCServiceDomain = @"local.";
static const uint32_t kSCProtocolVersion = 1;
static const uint32_t kSCMaxPayloadSize = 10 * 1024 * 1024;
static const NSUInteger kSCMaxConnections = 4;

static inline BOOL scReadEnabled(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("Enabled"), (CFStringRef)kSCPrefsSuite);
    if (!value) {
        return YES;
    }

    BOOL enabled = YES;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        enabled = CFBooleanGetValue((CFBooleanRef)value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int numeric = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &numeric)) {
            enabled = numeric != 0;
        }
    }
    CFRelease(value);
    return enabled;
}

static inline NSString *scDeviceIdentifier(void) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSCPrefsSuite];
    NSString *deviceID = [defaults stringForKey:@"DeviceID"];
    if (deviceID.length == 0) {
        deviceID = [[NSUUID UUID] UUIDString];
        [defaults setObject:deviceID forKey:@"DeviceID"];
        [defaults synchronize];
    }
    return deviceID;
}

static inline NSString *scSanitizedServiceName(NSString *rawName) {
    if (rawName.length == 0) {
        rawName = @"ShareClipboard iOS";
    }

    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"];
    NSMutableString *sanitized = [NSMutableString string];
    for (NSUInteger index = 0; index < rawName.length; index++) {
        unichar character = [rawName characterAtIndex:index];
        if (character == ' ' || character == '_') {
            [sanitized appendString:@"-"];
            continue;
        }
        if ([allowed characterIsMember:character]) {
            [sanitized appendFormat:@"%C", character];
        }
    }

    if (sanitized.length == 0) {
        return @"ShareClipboard-iOS";
    }
    if (sanitized.length > 63) {
        return [sanitized substringToIndex:63];
    }
    return sanitized;
}

static inline NSString *scContentFingerprint(NSString *type, NSData *payload) {
    if (!type || !payload) {
        return @"";
    }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(payload.bytes, (CC_LONG)payload.length, digest);
    NSMutableString *hash = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hash appendFormat:@"%02x", digest[index]];
    }
    return [NSString stringWithFormat:@"%@:%@", type, hash];
}
