#import <CoreFoundation/CoreFoundation.h>
#import <stdint.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

typedef float IOHIDFloat;

enum {
    kIOHIDDigitizerTransducerTypeHand = 3,
};

enum {
    kIOHIDDigitizerEventRange = 1 << 0,
    kIOHIDDigitizerEventTouch = 1 << 1,
    kIOHIDDigitizerEventPosition = 1 << 2,
    kIOHIDDigitizerEventIdentity = 1 << 5,
    kIOHIDDigitizerEventAttribute = 1 << 6,
};

enum {
    kIOHIDEventFieldIsBuiltIn = 0x00090001,
    kIOHIDEventFieldDigitizerIsDisplayIntegrated = 0x00090004,
    kIOHIDEventFieldDigitizerMajorRadius = 0x0009000B,
    kIOHIDEventFieldDigitizerMinorRadius = 0x0009000C,
};

enum {
    kIOHIDEventOptionNone = 0,
};

enum {
    kGSEventPathInfoInRange = 0x0001,
    kGSEventPathInfoInTouch = 0x0002,
};

// Sender ID used by TrollVNC / system touch synthesis (iOS 9+).
static const uint64_t kSMIOHIDSenderID = 0x8000000817319371ULL;

static const uint32_t kSMFingerIdentifier = 2;
static const IOHIDFloat kSMDefaultMajorRadius = 5.0f;

typedef IOHIDEventRef (*SMIOHIDEventCreateDigitizerEventFunc)(CFAllocatorRef allocator,
                                                              uint64_t timeStamp,
                                                              uint32_t type,
                                                              uint32_t index,
                                                              uint32_t identity,
                                                              uint32_t eventMask,
                                                              uint32_t buttonMask,
                                                              IOHIDFloat x,
                                                              IOHIDFloat y,
                                                              IOHIDFloat z,
                                                              IOHIDFloat tipPressure,
                                                              IOHIDFloat barrelPressure,
                                                              Boolean range,
                                                              Boolean touch,
                                                              uint32_t options);

typedef IOHIDEventRef (*SMIOHIDEventCreateDigitizerFingerEventFunc)(CFAllocatorRef allocator,
                                                                    uint64_t timeStamp,
                                                                    uint32_t index,
                                                                    uint32_t identity,
                                                                    uint32_t eventMask,
                                                                    IOHIDFloat x,
                                                                    IOHIDFloat y,
                                                                    IOHIDFloat z,
                                                                    IOHIDFloat tipPressure,
                                                                    IOHIDFloat twist,
                                                                    Boolean range,
                                                                    Boolean touch,
                                                                    uint32_t options);

// BackBoardServices ABI: absolute pixel coordinates + buttonMask.
typedef IOHIDEventRef (*SMIOHIDEventCreateBKSDigitizerFingerEventFunc)(CFAllocatorRef allocator,
                                                                         uint64_t timeStamp,
                                                                         uint32_t index,
                                                                         uint32_t identity,
                                                                         uint32_t eventMask,
                                                                         uint32_t buttonMask,
                                                                         IOHIDFloat x,
                                                                         IOHIDFloat y,
                                                                         IOHIDFloat z,
                                                                         IOHIDFloat tipPressure,
                                                                         IOHIDFloat barrelPressure,
                                                                         IOHIDFloat twist,
                                                                         Boolean range,
                                                                         Boolean touch,
                                                                         uint32_t options);

typedef IOHIDEventRef (*SMIOHIDEventCreateKeyboardEventFunc)(CFAllocatorRef allocator,
                                                             uint64_t timeStamp,
                                                             uint16_t usagePage,
                                                             uint16_t usage,
                                                             Boolean down,
                                                             uint32_t options);

typedef void (*SMIOHIDEventAppendEventFunc)(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
typedef void (*SMIOHIDEventSetIntegerValueFunc)(IOHIDEventRef event, int field, int value);
typedef void (*SMIOHIDEventSetFloatValueFunc)(IOHIDEventRef event, int field, IOHIDFloat value);
typedef void (*SMIOHIDEventSetSenderIDFunc)(IOHIDEventRef event, uint64_t senderID);
typedef IOHIDEventSystemClientRef (*SMIOHIDEventSystemClientCreateFunc)(CFAllocatorRef allocator);
typedef void (*SMIOHIDEventSystemClientDispatchEventFunc)(IOHIDEventSystemClientRef client, IOHIDEventRef event);
typedef void (*SMBKSHIDEventSendToSystemProcessFunc)(IOHIDEventRef event);
