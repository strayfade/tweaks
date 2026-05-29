TARGET := iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = shareclipboard

shareclipboard_FILES = Tweak.xm SCPasteboardAlerts.xm SCConnection.mm SCPasteboard.mm SCStreamRunLoop.m SCSyncEngine.mm
shareclipboard_CFLAGS = -fobjc-arc -w
shareclipboard_FRAMEWORKS = UIKit

include $(THEOS)/makefiles/tweak.mk
SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
