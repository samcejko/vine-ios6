# Revine - a tweak that brings the original Vine app (2.5.1) back to life with the content of diVine.
# Built with Theos for iOS 6.x (armv7, the iOS 9.3 SDK, deployment target 6.0): Vine 2.5.1 is a 32-bit app, so
# there is no arm64 build. CI builds it, see .github/workflows/build.yml.

TARGET := iphone:clang:9.3:6.0
ARCHS := armv7
DEBUG ?= 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := Revine

Revine_FILES := $(wildcard src/*.m) $(wildcard src/*/*.m) \
                vendor/mbedtls_glue.c \
                $(wildcard vendor/mbedtls/library/*.c)

Revine_FRAMEWORKS := UIKit Foundation CoreGraphics Security

# Flags for every C-family file (also the vendored mbedTLS sources)
Revine_CFLAGS := -Isrc -Isrc/Net \
                 -Ivendor -Ivendor/mbedtls/include -Ivendor/mbedtls/library \
                 -Os -fvisibility=hidden \
                 -Wall -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable \
                 -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-unused-parameter \
                 -Wno-nullability-completeness -Wno-nullability-completeness-on-arrays -Wno-error

# Objective-C only: ARC; APIs newer than iOS 6.0 are turned into errors for our sources by src/RVCommon.h
Revine_OBJCFLAGS := -fobjc-arc -Wunguarded-availability

Revine_LDFLAGS := -lz

include $(THEOS_MAKE_PATH)/tweak.mk

REVINE_STAGED_DYLIB := $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/Revine.dylib

# The iOS 9.3 SDK places the NSURL* loading classes (NSURLProtocol, NSHTTPURLResponse...) in CFNetwork; on iOS 6 they
# live in Foundation and dyld would refuse to load the tweak ("Symbol not found ... Expected in CFNetwork"). The
# CFNetwork load command is pointed at Foundation, then the dylib is signed again.
after-stage::
	install_name_tool -change /System/Library/Frameworks/CFNetwork.framework/CFNetwork /System/Library/Frameworks/Foundation.framework/Foundation "$(REVINE_STAGED_DYLIB)" || true
	ldid -S "$(REVINE_STAGED_DYLIB)"
