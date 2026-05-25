ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = splashtext

splashtext_FILES = splashtext.mm $(wildcard Cells/*.m Cells/*.mm)
splashtext_CFLAGS = -fobjc-arc -DPACKAGE_VERSION='@"$(THEOS_PACKAGE_BASE_VERSION)"'
splashtext_INSTALL_PATH = /Library/PreferenceBundles
splashtext_FRAMEWORKS = UIKit
splashtext_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS)/makefiles/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/splashtext.plist$(ECHO_END)
