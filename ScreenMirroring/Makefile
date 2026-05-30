TARGET := iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = screenmirroring

screenmirroring_FILES = Tweak.xm SMCommon.mm SMHardwareKeys.mm SMVNCCrypto.mm SMScreenCapture.mm SMIOMobileFramebufferHook.xm SMKeysymMap.mm SMInputInjector.mm SMVNCConnection.mm SMVNCServer.mm
screenmirroring_CFLAGS = -fobjc-arc -w
screenmirroring_FRAMEWORKS = UIKit CoreGraphics IOKit QuartzCore
screenmirroring_PRIVATE_FRAMEWORKS = BackBoardServices IOMobileFramebuffer
screenmirroring_LIBRARIES = objc

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
