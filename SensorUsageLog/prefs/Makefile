ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = sensorusagelog

sensorusagelog_FILES = sensorusagelog.mm $(wildcard Cells/*.m Cells/*.mm)
sensorusagelog_CFLAGS = -fobjc-arc -DPACKAGE_VERSION='@"$(THEOS_PACKAGE_BASE_VERSION)"'
sensorusagelog_INSTALL_PATH = /Library/PreferenceBundles
sensorusagelog_FRAMEWORKS = UIKit
sensorusagelog_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS)/makefiles/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/sensorusagelog.plist$(ECHO_END)
