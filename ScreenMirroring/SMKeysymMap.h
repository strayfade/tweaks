#import <stdint.h>

// Maps an RFB/X11 keysym to a USB HID keyboard usage (page 0x07). Returns 0 if unmapped.
uint32_t smHIDUsageForKeysym(uint32_t keysym);
