ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = lstext

lstext_FILES = lstext.mm $(wildcard Cells/*.m Cells/*.mm)
lstext_CFLAGS = -fobjc-arc -DPACKAGE_VERSION='@"$(THEOS_PACKAGE_BASE_VERSION)"'
lstext_INSTALL_PATH = /Library/PreferenceBundles
lstext_FRAMEWORKS = UIKit
lstext_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS)/makefiles/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/lstext.plist$(ECHO_END)
