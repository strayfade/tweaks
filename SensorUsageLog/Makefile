TARGET := iphone:clang:16.5:16.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = sensorusagelog

sensorusagelog_FILES = Tweak.xm
sensorusagelog_CFLAGS = -fobjc-arc -w
sensorusagelog_FRAMEWORKS = UIKit AVFoundation CoreLocation CoreMotion

include $(THEOS)/makefiles/tweak.mk
SUBPROJECTS += prefs
include $(THEOS)/makefiles/aggregate.mk
