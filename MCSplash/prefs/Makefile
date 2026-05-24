ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = mcsplash

mcsplash_FILES = mcsplash.mm $(wildcard Cells/*.m Cells/*.mm)
mcsplash_CFLAGS = -fobjc-arc -DPACKAGE_VERSION='@"$(THEOS_PACKAGE_BASE_VERSION)"'
mcsplash_INSTALL_PATH = /Library/PreferenceBundles
mcsplash_FRAMEWORKS = UIKit
mcsplash_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS)/makefiles/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/mcsplash.plist$(ECHO_END)
