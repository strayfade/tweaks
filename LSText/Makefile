TARGET := iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = lstext

lstext_FILES = Tweak.xm
lstext_CFLAGS = -fobjc-arc -w
lstext_FRAMEWORKS = UIKit

include $(THEOS)/makefiles/tweak.mk
SUBPROJECTS += prefs
include $(THEOS)/makefiles/aggregate.mk
