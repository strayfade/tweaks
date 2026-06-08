ARCHS = arm64 arm64e
# Main tweak uses a newer SDK for Swift/Metal; prefs need an SDK with Preferences.framework.
TARGET := iphone:clang:16.5:16.0

include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = liquidglass

liquidglass_FILES = liquidglass.mm $(wildcard Cells/*.m Cells/*.mm)
liquidglass_RESOURCE_DIRS = Resources
liquidglass_CFLAGS = -fobjc-arc -DPACKAGE_VERSION='@"$(THEOS_PACKAGE_BASE_VERSION)"'
liquidglass_INSTALL_PATH = /Library/PreferenceBundles
liquidglass_FRAMEWORKS = UIKit
liquidglass_PRIVATE_FRAMEWORKS = Preferences
liquidglass_LDFLAGS = -F$(SYSROOT)/System/Library/PrivateFrameworks

include $(THEOS)/makefiles/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/liquidglass.plist$(ECHO_END)
