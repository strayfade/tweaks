#import <Foundation/Foundation.h>

static NSString *const kSMPrefsSuite = @"com.strayfade.screenmirroring~prefs";
static NSString *const kSMServiceType = @"_screenmirroring._tcp.";
static NSString *const kSMRfbServiceType = @"_rfb._tcp.";
static NSString *const kSMServiceDomain = @"local.";
static const NSUInteger kSMMaxConnections = 2;
static const uint16_t kSMServerPort = 45900;
static const uint32_t kSMProtocolVersion = 1;

double smPreferredFrameRate(void);

BOOL smReadEnabled(void);
BOOL smReadLiveCapture(void);
NSString *smReadPassword(void);
NSInteger smReadFrameScale(void);
NSInteger smEffectiveFrameScale(void);
BOOL smFileLoggingEnabled(void);

NSString *smSanitizedServiceName(NSString *rawName);
NSString *smDeviceIdentifier(void);
void smLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
