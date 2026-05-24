TARGET := iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = mcsplash

mcsplash_FILES = Tweak.xm
mcsplash_CFLAGS = -fobjc-arc -w
mcsplash_FRAMEWORKS = UIKit CoreText

include $(THEOS)/makefiles/tweak.mk
SUBPROJECTS += prefs
include $(THEOS)/makefiles/aggregate.mk

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/Application Support/MCSplash"$(ECHO_END)
	$(ECHO_NOTHING)if [ -f "Minecraft.ttf" ]; then cp "Minecraft.ttf" "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/Application Support/MCSplash/minecraft.ttf"; elif [ -f "minecraft.ttf" ]; then cp "minecraft.ttf" "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/Application Support/MCSplash/minecraft.ttf"; else echo "Missing Minecraft.ttf in tweak root"; exit 1; fi$(ECHO_END)
