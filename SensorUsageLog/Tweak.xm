#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>
#import <rootless.h>

static NSString *const kSensorWatchPrefsID = @"com.strayfade.sensorusagelog~prefs";
static NSString *const kSensorWatchEnabledKey = @"Enabled";
static NSString *const kSensorWatchLogPathKey = @"CustomLogPath";
static NSString *const kSensorWatchTrackCameraKey = @"TrackCamera";
static NSString *const kSensorWatchTrackMicrophoneKey = @"TrackMicrophone";
static NSString *const kSensorWatchTrackLocationKey = @"TrackLocation";
static NSString *const kSensorWatchTrackMotionKey = @"TrackMotion";
static NSString *const kSensorWatchDetailedMetadataKey = @"DetailedMetadata";
static NSString *const kSensorWatchMaxLogLinesKey = @"MaxLogLines";

static NSString *sensorwatchDefaultLogPath() {
    return ROOT_PATH_NS(@"/var/mobile/Library/Preferences/com.strayfade.sensorusagelog.events.jsonl");
}

static BOOL sensorwatchReadBool(NSString *key, BOOL fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kSensorWatchPrefsID);
    if (!value) {
        return fallback;
    }

    BOOL result = fallback;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int numeric = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &numeric)) {
            result = numeric != 0;
        }
    }
    CFRelease(value);
    return result;
}

static NSInteger sensorwatchReadInteger(NSString *key, NSInteger fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kSensorWatchPrefsID);
    if (!value) {
        return fallback;
    }

    NSInteger result = fallback;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberNSIntegerType, &result);
    }
    CFRelease(value);
    return result;
}

static NSString *sensorwatchReadString(NSString *key, NSString *fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kSensorWatchPrefsID);
    if (!value) {
        return fallback;
    }

    NSString *result = fallback;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        NSString *candidate = [(__bridge NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (candidate.length > 0) {
            result = candidate;
        }
    }
    CFRelease(value);
    return result;
}

static NSString *sensorwatchBundleID() {
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    if (!bundleID || bundleID.length == 0) {
        bundleID = [[NSProcessInfo processInfo] processName] ?: @"unknown.process";
    }
    return bundleID;
}

static NSString *sensorwatchProcessName() {
    return [[NSProcessInfo processInfo] processName] ?: @"unknown";
}

static NSMutableDictionary<NSString *, NSDate *> *sensorwatchActiveSessions() {
    static NSMutableDictionary<NSString *, NSDate *> *sessions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sessions = [NSMutableDictionary dictionary];
    });
    return sessions;
}

static dispatch_queue_t sensorwatchLogQueue() {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.strayfade.sensorusagelog.log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSDictionary *sensorwatchCurrentSettings() {
    return @{
        @"enabled": @(sensorwatchReadBool(kSensorWatchEnabledKey, YES)),
        @"trackCamera": @(sensorwatchReadBool(kSensorWatchTrackCameraKey, YES)),
        @"trackMicrophone": @(sensorwatchReadBool(kSensorWatchTrackMicrophoneKey, YES)),
        @"trackLocation": @(sensorwatchReadBool(kSensorWatchTrackLocationKey, YES)),
        @"trackMotion": @(sensorwatchReadBool(kSensorWatchTrackMotionKey, YES)),
        @"detailedMetadata": @(sensorwatchReadBool(kSensorWatchDetailedMetadataKey, YES)),
        @"maxLogLines": @(MAX(sensorwatchReadInteger(kSensorWatchMaxLogLinesKey, 5000), 100))
    };
}

static BOOL sensorwatchShouldTrackSensor(NSString *sensorName) {
    NSDictionary *settings = sensorwatchCurrentSettings();
    if (![settings[@"enabled"] boolValue]) {
        return NO;
    }

    if ([sensorName isEqualToString:@"camera"]) {
        return [settings[@"trackCamera"] boolValue];
    }
    if ([sensorName isEqualToString:@"microphone"]) {
        return [settings[@"trackMicrophone"] boolValue];
    }
    if ([sensorName isEqualToString:@"location"]) {
        return [settings[@"trackLocation"] boolValue];
    }
    if ([sensorName isEqualToString:@"motion"]) {
        return [settings[@"trackMotion"] boolValue];
    }
    return YES;
}

static void sensorwatchTrimLogIfNeeded(NSString *logPath, NSInteger maxLines) {
    NSString *content = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
    if (content.length == 0) {
        return;
    }

    NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
    if ((NSInteger)lines.count <= maxLines + 1) {
        return;
    }

    NSInteger firstLine = lines.count - maxLines - 1;
    if (firstLine < 0) {
        firstLine = 0;
    }
    NSArray<NSString *> *tail = [lines subarrayWithRange:NSMakeRange((NSUInteger)firstLine, lines.count - (NSUInteger)firstLine)];
    NSString *trimmed = [tail componentsJoinedByString:@"\n"];
    [trimmed writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void sensorwatchWriteEvent(NSString *sensor, NSString *eventType, NSDictionary *metadata, NSNumber *durationMs) {
    if (!sensorwatchShouldTrackSensor(sensor)) {
        return;
    }

    NSDictionary *settings = sensorwatchCurrentSettings();
    BOOL includeMetadata = [settings[@"detailedMetadata"] boolValue];
    NSInteger maxLogLines = [settings[@"maxLogLines"] integerValue];
    NSString *logPath = sensorwatchReadString(kSensorWatchLogPathKey, sensorwatchDefaultLogPath());
    if (logPath.length == 0) {
        logPath = sensorwatchDefaultLogPath();
    }

    NSMutableDictionary *event = [NSMutableDictionary dictionary];
    event[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    event[@"iso8601"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    event[@"pid"] = @([[NSProcessInfo processInfo] processIdentifier]);
    event[@"processName"] = sensorwatchProcessName();
    event[@"bundleID"] = sensorwatchBundleID();
    event[@"sensor"] = sensor ?: @"unknown";
    event[@"eventType"] = eventType ?: @"event";

    if (durationMs) {
        event[@"durationMs"] = durationMs;
    }
    if (includeMetadata && metadata.count > 0) {
        event[@"metadata"] = metadata;
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!jsonData) {
        return;
    }

    dispatch_async(sensorwatchLogQueue(), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *directory = [logPath stringByDeletingLastPathComponent];
        if (directory.length > 0 && ![fm fileExistsAtPath:directory]) {
            [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        }
        if (![fm fileExistsAtPath:logPath]) {
            [@"" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!handle) {
            return;
        }

        @try {
            [handle seekToEndOfFile];
            [handle writeData:jsonData];
            [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
            sensorwatchTrimLogIfNeeded(logPath, maxLogLines);
        } @catch (NSException *exception) {
            [handle closeFile];
            NSLog(@"[SensorUsageLog] failed writing event: %@", exception);
        }
    });
}

static void sensorwatchStartSession(NSString *sensor, NSDictionary *metadata) {
    if (!sensorwatchShouldTrackSensor(sensor)) {
        return;
    }

    NSString *sessionKey = [NSString stringWithFormat:@"%@:%@", sensorwatchBundleID(), sensor];
    sensorwatchActiveSessions()[sessionKey] = [NSDate date];
    sensorwatchWriteEvent(sensor, @"start", metadata, nil);
}

static void sensorwatchStopSession(NSString *sensor, NSDictionary *metadata) {
    if (!sensorwatchShouldTrackSensor(sensor)) {
        return;
    }

    NSString *sessionKey = [NSString stringWithFormat:@"%@:%@", sensorwatchBundleID(), sensor];
    NSDate *start = sensorwatchActiveSessions()[sessionKey];
    NSNumber *durationMs = nil;
    if (start) {
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:start] * 1000.0;
        durationMs = @((long long)MAX(elapsed, 0));
        [sensorwatchActiveSessions() removeObjectForKey:sessionKey];
    }
    sensorwatchWriteEvent(sensor, @"stop", metadata, durationMs);
}

%hook AVCaptureSession
- (void)startRunning {
    sensorwatchStartSession(@"camera", @{@"api": @"AVCaptureSession.startRunning"});
    %orig;
}

- (void)stopRunning {
    sensorwatchStopSession(@"camera", @{@"api": @"AVCaptureSession.stopRunning"});
    %orig;
}
%end

%hook AVCaptureDevice
+ (void)requestAccessForMediaType:(AVMediaType)mediaType completionHandler:(void (^)(BOOL granted))completionHandler {
    NSString *sensor = @"camera";
    if ([mediaType isEqualToString:AVMediaTypeAudio]) {
        sensor = @"microphone";
    }

    sensorwatchWriteEvent(sensor, @"permission_request", @{@"api": @"AVCaptureDevice.requestAccessForMediaType"}, nil);
    %orig(mediaType, completionHandler);
}
%end

%hook AVAudioSession
- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    BOOL result = %orig;
    if (result) {
        if (active) {
            sensorwatchStartSession(@"microphone", @{@"api": @"AVAudioSession.setActive", @"value": @"YES"});
        } else {
            sensorwatchStopSession(@"microphone", @{@"api": @"AVAudioSession.setActive", @"value": @"NO"});
        }
    }
    return result;
}
%end

%hook CLLocationManager
- (void)requestWhenInUseAuthorization {
    sensorwatchWriteEvent(@"location", @"permission_request", @{@"api": @"CLLocationManager.requestWhenInUseAuthorization"}, nil);
    %orig;
}

- (void)requestAlwaysAuthorization {
    sensorwatchWriteEvent(@"location", @"permission_request", @{@"api": @"CLLocationManager.requestAlwaysAuthorization"}, nil);
    %orig;
}

- (void)startUpdatingLocation {
    sensorwatchStartSession(@"location", @{@"api": @"CLLocationManager.startUpdatingLocation"});
    %orig;
}

- (void)stopUpdatingLocation {
    sensorwatchStopSession(@"location", @{@"api": @"CLLocationManager.stopUpdatingLocation"});
    %orig;
}
%end

%hook CMMotionManager
- (void)startAccelerometerUpdates {
    sensorwatchStartSession(@"motion", @{@"api": @"CMMotionManager.startAccelerometerUpdates"});
    %orig;
}

- (void)stopAccelerometerUpdates {
    sensorwatchStopSession(@"motion", @{@"api": @"CMMotionManager.stopAccelerometerUpdates"});
    %orig;
}

- (void)startGyroUpdates {
    sensorwatchStartSession(@"motion", @{@"api": @"CMMotionManager.startGyroUpdates"});
    %orig;
}

- (void)stopGyroUpdates {
    sensorwatchStopSession(@"motion", @{@"api": @"CMMotionManager.stopGyroUpdates"});
    %orig;
}

- (void)startDeviceMotionUpdates {
    sensorwatchStartSession(@"motion", @{@"api": @"CMMotionManager.startDeviceMotionUpdates"});
    %orig;
}

- (void)stopDeviceMotionUpdates {
    sensorwatchStopSession(@"motion", @{@"api": @"CMMotionManager.stopDeviceMotionUpdates"});
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        if (!sensorwatchReadBool(kSensorWatchEnabledKey, YES)) {
            return;
        }
        NSLog(@"[SensorUsageLog] loaded for %@", sensorwatchBundleID());
        %init;
    }
}
