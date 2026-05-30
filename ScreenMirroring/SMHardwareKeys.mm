#import "SMHardwareKeys.h"

enum {
    kSMKeysym_F1 = 0xffbe,
    kSMKeysym_F5 = 0xffc2,
};

static SMHardwareButtonAction smDefaultActionForFunctionKey(int functionKeyNumber) {
    switch (functionKeyNumber) {
        case 1:
            return SMHardwareButtonActionVolumeUp;
        case 2:
            return SMHardwareButtonActionVolumeDown;
        case 3:
            return SMHardwareButtonActionSideButton;
        case 4:
            return SMHardwareButtonActionHome;
        case 5:
            return SMHardwareButtonActionAppSwitcher;
        default:
            return SMHardwareButtonActionNone;
    }
}

BOOL smKeysymIsFunctionKey(uint32_t keysym, int *functionKeyNumberOut) {
    if (keysym < kSMKeysym_F1 || keysym > kSMKeysym_F5) {
        return NO;
    }
    const int functionKeyNumber = (int)(keysym - kSMKeysym_F1) + 1;
    if (functionKeyNumber < 1 || functionKeyNumber > 5) {
        return NO;
    }
    if (functionKeyNumberOut) {
        *functionKeyNumberOut = functionKeyNumber;
    }
    return YES;
}

SMHardwareButtonAction smHardwareButtonActionForKeysym(uint32_t keysym) {
    int functionKeyNumber = 0;
    if (!smKeysymIsFunctionKey(keysym, &functionKeyNumber)) {
        return SMHardwareButtonActionNone;
    }
    return smDefaultActionForFunctionKey(functionKeyNumber);
}
