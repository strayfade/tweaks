# ---------------------------------------------------------------
# LiquidGlass – iOS 16 Jailbreak Tweak
# Requires Theos (https://theos.dev) and Xcode 16+
# Target device: arm64 iPhone/iPad running iOS 14.0 – 16.x (jailbroken)
# ---------------------------------------------------------------

export ARCHS = arm64 arm64e
# clang:<sdk-version>:<deployment-target>
export TARGET = iphone:clang:26.0:14.0
# Default scheme is rootless. Pass THEOS_PACKAGE_SCHEME=roothide on the command
# line (make THEOS_PACKAGE_SCHEME=roothide package) to produce the roothide .deb.
# Both schemes install to /var/jb — RootHide remaps that to its hidden path at runtime.
THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_SCHEME
# Swift 6 is required – internal import + trailing‐comma call syntax
export SWIFT_VERSION = 6

include $(THEOS)/makefiles/common.mk

# ---------------------------------------------------------------
# Tweak target
# ---------------------------------------------------------------
TWEAK_NAME = LiquidGlass

# All Swift source files compiled into the dylib.
# Theos runs one WMO swiftc invocation for all SWIFT_FILES (see SWIFT_OPTFLAG in Theos).
# Build progress names the last Swift file in this list — not the slowest file.
# Put the largest sources last so logs match where time is spent (~3k-line Bridge).
LiquidGlass_FILES = \
	Tweak.x \
	LiquidGlassAL.x \
	Sources/LiquidGlassKit/ZeroCopyBridge.swift \
	Sources/GlassMotionController.swift \
	Sources/GlassPreferences.swift \
	Sources/LiquidGlassKit/LiquidGlassEffectView.swift \
	Sources/LiquidGlassKit/LiquidGlassSlider.swift \
	Sources/LiquidGlassKit/LiquidGlassSwitch.swift \
	Sources/LiquidGlassKit/LiquidLensView.swift \
	Sources/LiquidGlassKit/LiquidGlassView.swift \
	Sources/LiquidGlassBridge.swift

LiquidGlass_CFLAGS   = -fobjc-arc
# Suppress Swift 6 strict-concurrency warnings that don't affect runtime.
# -num-threads speeds up Theos's default -whole-module-optimization pass on the Mac builder.
LiquidGlass_SWIFTFLAGS = -suppress-warnings -num-threads 4
# Faster iterative builds (disable WMO; release can keep Theos default -O -whole-module-optimization):
# LiquidGlass_SWIFT_OPTFLAG = -O

LiquidGlass_FRAMEWORKS = \
	UIKit \
	MetalKit \
	MetalPerformanceShaders \
	CoreVideo \
	CoreMotion

# ---------------------------------------------------------------
# Shader pre-compilation step
# Produces layout/Library/LiquidGlass/LiquidGlassKitShaderResources.bundle/default.metallib
# before the tweak dylib is linked.
# ---------------------------------------------------------------
SHADER_BUNDLE  = layout/Library/LiquidGlass/LiquidGlassKitShaderResources.bundle
SHADER_SRC     = Sources/LiquidGlassKit
AIR_FRAG       = $(THEOS_OBJ_DIR)/LGFragment.air
AIR_VERT       = $(THEOS_OBJ_DIR)/LGVertex.air

before-all::
	@echo "[LiquidGlass] Compiling Metal shaders for iOS arm64…"
	@mkdir -p $(SHADER_BUNDLE) $(THEOS_OBJ_DIR)
	xcrun -sdk iphoneos metal \
		-target air64-apple-ios14.0 \
		-c $(SHADER_SRC)/LiquidGlassFragment.metal \
		-o $(AIR_FRAG)
	xcrun -sdk iphoneos metal \
		-target air64-apple-ios14.0 \
		-c $(SHADER_SRC)/LiquidGlassVertex.metal \
		-o $(AIR_VERT)
	xcrun -sdk iphoneos metallib \
		$(AIR_FRAG) $(AIR_VERT) \
		-o $(SHADER_BUNDLE)/default.metallib
	@echo "[LiquidGlass] Metal shaders compiled → $(SHADER_BUNDLE)/default.metallib"

# ---------------------------------------------------------------
include $(THEOS)/makefiles/tweak.mk
SUBPROJECTS += prefs
include $(THEOS)/makefiles/aggregate.mk
