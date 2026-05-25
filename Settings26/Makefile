TARGET := iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = Preferences
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = settings26

settings26_FILES = Tweak.xm
settings26_CFLAGS = -fobjc-arc -w
settings26_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
