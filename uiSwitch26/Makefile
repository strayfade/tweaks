TARGET := iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = switchwidth

switchwidth_FILES = Tweak.xm
switchwidth_CFLAGS = -fobjc-arc -w
switchwidth_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
