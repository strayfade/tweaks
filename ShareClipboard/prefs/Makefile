ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = shareclipboard

shareclipboard_FILES = shareclipboard.mm $(wildcard Cells/*.m Cells/*.mm)
shareclipboard_CFLAGS = -fobjc-arc -DPACKAGE_VERSION='@"$(THEOS_PACKAGE_BASE_VERSION)"'
shareclipboard_INSTALL_PATH = /Library/PreferenceBundles
shareclipboard_FRAMEWORKS = UIKit
shareclipboard_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS)/makefiles/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/shareclipboard.plist$(ECHO_END)
