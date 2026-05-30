#import "SMCommon.h"
#import <stdarg.h>

static CFPropertyListRef smCopyPreference(CFStringRef key);

double smPreferredFrameRate(void) {
    CFPropertyListRef value = smCopyPreference(CFSTR("FrameRate"));
    if (!value) {
        return 60.0;
    }

    double frameRate = 60.0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &frameRate);
    } else if (CFGetTypeID(value) == CFStringGetTypeID()) {
        frameRate = [(__bridge NSString *)value doubleValue];
    }
    CFRelease(value);

    if (frameRate < 15.0) {
        frameRate = 15.0;
    }
    if (frameRate > 60.0) {
        frameRate = 60.0;
    }
    return frameRate;
}

static NSString *smLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
            path = @"/var/jb/var/mobile/Library/Preferences/com.strayfade.screenmirroring.log";
        } else {
            path = @"/var/mobile/Library/Preferences/com.strayfade.screenmirroring.log";
        }
    });
    return path;
}

static void smAppendLogLine(NSString *line) {
    if (!line) {
        return;
    }

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", timestamp, line];
    NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];

    NSString *logPath = smLogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        [data writeToFile:logPath atomically:YES];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!handle) {
        [data writeToFile:logPath atomically:YES];
        return;
    }

    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } @catch (__unused NSException *exception) {
        [handle closeFile];
    }
}

BOOL smFileLoggingEnabled(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CFPropertyListRef value = smCopyPreference(CFSTR("DebugLog"));
        if (!value) {
            return;
        }
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            enabled = CFBooleanGetValue((CFBooleanRef)value);
        } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            int numeric = 0;
            if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &numeric)) {
                enabled = numeric != 0;
            }
        }
        CFRelease(value);
    });
    return enabled;
}

void smLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

#if DEBUG
    NSLog(@"[ScreenMirroring] %@", message);
#endif
    if (smFileLoggingEnabled()) {
        smAppendLogLine(message);
    }
}

NSInteger smEffectiveFrameScale(void) {
    const NSInteger scale = smReadFrameScale();
    return scale < 2 ? 2 : scale;
}

static CFPropertyListRef smCopyPreference(CFStringRef key) {
    return CFPreferencesCopyAppValue(key, (CFStringRef)kSMPrefsSuite);
}

BOOL smReadEnabled(void) {
    CFPropertyListRef value = smCopyPreference(CFSTR("Enabled"));
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

BOOL smReadLiveCapture(void) {
    CFPropertyListRef value = smCopyPreference(CFSTR("LiveCapture"));
    if (!value) {
        return YES;
    }

    BOOL liveCapture = YES;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        liveCapture = CFBooleanGetValue((CFBooleanRef)value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int numeric = 1;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &numeric)) {
            liveCapture = numeric != 0;
        }
    }
    CFRelease(value);
    return liveCapture;
}

NSString *smReadPassword(void) {
    CFPropertyListRef value = smCopyPreference(CFSTR("Password"));
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        if (value) {
            CFRelease(value);
        }
        return @"";
    }

    NSString *password = [(__bridge NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    CFRelease(value);
    return password ?: @"";
}

NSInteger smReadFrameScale(void) {
    CFPropertyListRef value = smCopyPreference(CFSTR("FrameScale"));
    if (!value) {
        return 2;
    }

    NSInteger scale = 2;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberNSIntegerType, &scale);
    } else if (CFGetTypeID(value) == CFStringGetTypeID()) {
        scale = [(__bridge NSString *)value integerValue];
    }
    CFRelease(value);

    if (scale < 1) {
        scale = 1;
    }
    if (scale > 4) {
        scale = 4;
    }
    return scale;
}

NSString *smDeviceIdentifier(void) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSMPrefsSuite];
    NSString *deviceID = [defaults stringForKey:@"DeviceID"];
    if (deviceID.length == 0) {
        deviceID = [[NSUUID UUID] UUIDString];
        [defaults setObject:deviceID forKey:@"DeviceID"];
        [defaults synchronize];
    }
    return deviceID;
}

NSString *smSanitizedServiceName(NSString *rawName) {
    if (rawName.length == 0) {
        rawName = @"Screen-Mirroring-iOS";
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
        return @"Screen-Mirroring-iOS";
    }
    if (sanitized.length > 63) {
        return [sanitized substringToIndex:63];
    }
    return sanitized;
}
