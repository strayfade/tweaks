#import <Foundation/Foundation.h>
#import <stdint.h>

typedef NS_ENUM(NSInteger, SMHardwareButtonAction) {
    SMHardwareButtonActionNone = 0,
    SMHardwareButtonActionVolumeUp,
    SMHardwareButtonActionVolumeDown,
    SMHardwareButtonActionSideButton,
    SMHardwareButtonActionHome,
    SMHardwareButtonActionAppSwitcher,
};

BOOL smKeysymIsFunctionKey(uint32_t keysym, int *functionKeyNumberOut);
SMHardwareButtonAction smHardwareButtonActionForKeysym(uint32_t keysym);
