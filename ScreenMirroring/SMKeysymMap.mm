#import "SMKeysymMap.h"
#import "SMHIDUsages.h"
#import <Foundation/Foundation.h>

// X11 keysyms (RFB KeyEvent).
enum {
    kSMKeysym_BackSpace = 0xff08,
    kSMKeysym_Tab = 0xff09,
    kSMKeysym_Linefeed = 0xff0a,
    kSMKeysym_Return = 0xff0d,
    kSMKeysym_Escape = 0xff1b,
    kSMKeysym_Delete = 0xffff,
    kSMKeysym_Home = 0xff50,
    kSMKeysym_Left = 0xff51,
    kSMKeysym_Up = 0xff52,
    kSMKeysym_Right = 0xff53,
    kSMKeysym_Down = 0xff54,
    kSMKeysym_Page_Up = 0xff55,
    kSMKeysym_Page_Down = 0xff56,
    kSMKeysym_End = 0xff57,
    kSMKeysym_Insert = 0xff63,
    kSMKeysym_KP_Enter = 0xff8d,
    kSMKeysym_space = 0x020,
    kSMKeysym_Shift_L = 0xffe1,
    kSMKeysym_Shift_R = 0xffe2,
    kSMKeysym_Control_L = 0xffe3,
    kSMKeysym_Control_R = 0xffe4,
    kSMKeysym_Alt_L = 0xffe9,
    kSMKeysym_Alt_R = 0xffea,
    kSMKeysym_Meta_L = 0xffe7,
    kSMKeysym_Meta_R = 0xffe8,
    kSMKeysym_Super_L = 0xffeb,
    kSMKeysym_Super_R = 0xffec,
    kSMKeysym_ISO_Level3_Shift = 0xfe03,
    kSMKeysym_Mode_switch = 0xff7e,
    kSMKeysym_F1 = 0xffbe,
    kSMKeysym_F24 = 0xffd7,
};

static NSString *smKeyNameForKeysym(uint32_t keysym) {
    if ((keysym >= 0x20 && keysym <= 0x7E) || keysym == kSMKeysym_space) {
        unichar ch = (unichar)keysym;
        return [NSString stringWithCharacters:&ch length:1];
    }

    switch (keysym) {
        case kSMKeysym_Return:
        case kSMKeysym_KP_Enter:
            return @"RETURN";
        case kSMKeysym_Tab:
            return @"TAB";
        case kSMKeysym_Escape:
            return @"ESCAPE";
        case kSMKeysym_BackSpace:
            return @"BACKSPACE";
        case kSMKeysym_Delete:
            return @"FORWARDDELETE";
        case kSMKeysym_Insert:
            return @"INSERT";
        case kSMKeysym_Home:
            return @"HOME";
        case kSMKeysym_End:
            return @"END";
        case kSMKeysym_Page_Up:
            return @"PAGEUP";
        case kSMKeysym_Page_Down:
            return @"PAGEDOWN";
        case kSMKeysym_Left:
            return @"LEFTARROW";
        case kSMKeysym_Right:
            return @"RIGHTARROW";
        case kSMKeysym_Up:
            return @"UPARROW";
        case kSMKeysym_Down:
            return @"DOWNARROW";
        case kSMKeysym_Shift_L:
            return @"LEFTSHIFT";
        case kSMKeysym_Shift_R:
            return @"RIGHTSHIFT";
        case kSMKeysym_Control_L:
            return @"LEFTCONTROL";
        case kSMKeysym_Control_R:
            return @"RIGHTCONTROL";
        case kSMKeysym_Alt_L:
            return @"LEFTALT";
        case kSMKeysym_Alt_R:
            return @"RIGHTALT";
        case kSMKeysym_ISO_Level3_Shift:
            return @"LEFTALT";
        case kSMKeysym_Mode_switch:
            return @"RIGHTALT";
        case kSMKeysym_Meta_L:
            return @"LEFTCOMMAND";
        case kSMKeysym_Meta_R:
            return @"RIGHTCOMMAND";
        case kSMKeysym_Super_L:
            return @"LEFTCOMMAND";
        case kSMKeysym_Super_R:
            return @"RIGHTCOMMAND";
        default:
            break;
    }

    if (keysym >= kSMKeysym_F1 && keysym <= kSMKeysym_F24) {
        return [NSString stringWithFormat:@"F%d", (int)(keysym - kSMKeysym_F1) + 1];
    }

    return nil;
}

static uint32_t smHIDUsageForFunctionKeyName(NSString *key) {
    for (int i = 1; i <= 12; ++i) {
        if ([key isEqualToString:[NSString stringWithFormat:@"F%d", i]]) {
            return (uint32_t)(kSMHIDUsage_KeyboardF1 + i - 1);
        }
    }
    for (int i = 13; i <= 24; ++i) {
        if ([key isEqualToString:[NSString stringWithFormat:@"F%d", i]]) {
            return (uint32_t)(kSMHIDUsage_KeyboardF13 + i - 13);
        }
    }
    return 0;
}

static uint32_t smHIDUsageForKeyName(NSString *key) {
    const int uppercaseAlphabeticOffset = 'A' - kSMHIDUsage_KeyboardA;
    const int lowercaseAlphabeticOffset = 'a' - kSMHIDUsage_KeyboardA;
    const int numericNonZeroOffset = '1' - kSMHIDUsage_Keyboard1;

    if (key.length == 1) {
        const int keyCode = [key characterAtIndex:0];
        if (keyCode >= 97 && keyCode <= 122) {
            return (uint32_t)(keyCode - lowercaseAlphabeticOffset);
        }
        if (keyCode >= 65 && keyCode <= 90) {
            return (uint32_t)(keyCode - uppercaseAlphabeticOffset);
        }
        if (keyCode >= 49 && keyCode <= 57) {
            return (uint32_t)(keyCode - numericNonZeroOffset);
        }

        switch (keyCode) {
            case '`':
            case '~':
                return kSMHIDUsage_KeyboardGraveAccentAndTilde;
            case '!':
                return kSMHIDUsage_Keyboard1;
            case '@':
                return kSMHIDUsage_Keyboard2;
            case '#':
                return kSMHIDUsage_Keyboard3;
            case '$':
                return kSMHIDUsage_Keyboard4;
            case '%':
                return kSMHIDUsage_Keyboard5;
            case '^':
                return kSMHIDUsage_Keyboard6;
            case '&':
                return kSMHIDUsage_Keyboard7;
            case '*':
                return kSMHIDUsage_Keyboard8;
            case '(':
                return kSMHIDUsage_Keyboard9;
            case ')':
            case '0':
                return kSMHIDUsage_Keyboard0;
            case '-':
            case '_':
                return kSMHIDUsage_KeyboardHyphen;
            case '=':
            case '+':
                return kSMHIDUsage_KeyboardEqualSign;
            case '\b':
                return kSMHIDUsage_KeyboardDeleteOrBackspace;
            case '\t':
                return kSMHIDUsage_KeyboardTab;
            case '[':
            case '{':
                return kSMHIDUsage_KeyboardOpenBracket;
            case ']':
            case '}':
                return kSMHIDUsage_KeyboardCloseBracket;
            case '\\':
            case '|':
                return kSMHIDUsage_KeyboardBackslash;
            case ';':
            case ':':
                return kSMHIDUsage_KeyboardSemicolon;
            case '\'':
            case '"':
                return kSMHIDUsage_KeyboardQuote;
            case '\r':
            case '\n':
                return kSMHIDUsage_KeyboardReturnOrEnter;
            case ',':
            case '<':
                return kSMHIDUsage_KeyboardComma;
            case '.':
            case '>':
                return kSMHIDUsage_KeyboardPeriod;
            case '/':
            case '?':
                return kSMHIDUsage_KeyboardSlash;
            case ' ':
                return kSMHIDUsage_KeyboardSpacebar;
            default:
                break;
        }
    }

    uint32_t functionUsage = smHIDUsageForFunctionKeyName(key);
    if (functionUsage != 0) {
        return functionUsage;
    }

    key = [key uppercaseString];
    if ([key isEqualToString:@"CAPSLOCK"]) {
        return kSMHIDUsage_KeyboardCapsLock;
    }
    if ([key isEqualToString:@"PAGEUP"]) {
        return kSMHIDUsage_KeyboardPageUp;
    }
    if ([key isEqualToString:@"PAGEDOWN"]) {
        return kSMHIDUsage_KeyboardPageDown;
    }
    if ([key isEqualToString:@"HOME"]) {
        return kSMHIDUsage_KeyboardHome;
    }
    if ([key isEqualToString:@"INSERT"]) {
        return kSMHIDUsage_KeyboardInsert;
    }
    if ([key isEqualToString:@"END"]) {
        return kSMHIDUsage_KeyboardEnd;
    }
    if ([key isEqualToString:@"ESCAPE"]) {
        return kSMHIDUsage_KeyboardEscape;
    }
    if ([key isEqualToString:@"RETURN"] || [key isEqualToString:@"ENTER"]) {
        return kSMHIDUsage_KeyboardReturnOrEnter;
    }
    if ([key isEqualToString:@"LEFTARROW"]) {
        return kSMHIDUsage_KeyboardLeftArrow;
    }
    if ([key isEqualToString:@"RIGHTARROW"]) {
        return kSMHIDUsage_KeyboardRightArrow;
    }
    if ([key isEqualToString:@"UPARROW"]) {
        return kSMHIDUsage_KeyboardUpArrow;
    }
    if ([key isEqualToString:@"DOWNARROW"]) {
        return kSMHIDUsage_KeyboardDownArrow;
    }
    if ([key isEqualToString:@"DELETE"] || [key isEqualToString:@"BACKSPACE"]) {
        return kSMHIDUsage_KeyboardDeleteOrBackspace;
    }
    if ([key isEqualToString:@"FORWARDDELETE"]) {
        return kSMHIDUsage_KeyboardDeleteForward;
    }
    if ([key isEqualToString:@"LEFTCOMMAND"] || [key isEqualToString:@"COMMAND"]) {
        return kSMHIDUsage_KeyboardLeftGUI;
    }
    if ([key isEqualToString:@"RIGHTCOMMAND"]) {
        return kSMHIDUsage_KeyboardRightGUI;
    }
    if ([key isEqualToString:@"LEFTCONTROL"] || [key isEqualToString:@"CTRL"]) {
        return kSMHIDUsage_KeyboardLeftControl;
    }
    if ([key isEqualToString:@"RIGHTCONTROL"]) {
        return kSMHIDUsage_KeyboardRightControl;
    }
    if ([key isEqualToString:@"LEFTSHIFT"] || [key isEqualToString:@"SHIFT"]) {
        return kSMHIDUsage_KeyboardLeftShift;
    }
    if ([key isEqualToString:@"RIGHTSHIFT"]) {
        return kSMHIDUsage_KeyboardRightShift;
    }
    if ([key isEqualToString:@"LEFTALT"] || [key isEqualToString:@"ALT"]) {
        return kSMHIDUsage_KeyboardLeftAlt;
    }
    if ([key isEqualToString:@"RIGHTALT"]) {
        return kSMHIDUsage_KeyboardRightAlt;
    }
    if ([key isEqualToString:@"TAB"]) {
        return kSMHIDUsage_KeyboardTab;
    }
    if ([key isEqualToString:@"SPACE"]) {
        return kSMHIDUsage_KeyboardSpacebar;
    }

    return 0;
}

uint32_t smHIDUsageForKeysym(uint32_t keysym) {
    NSString *keyName = smKeyNameForKeysym(keysym);
    if (!keyName) {
        return 0;
    }
    return smHIDUsageForKeyName(keyName);
}
