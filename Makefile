ifeq ($(shell [ -f ./framework/makefiles/common.mk ] && echo 1 || echo 0),0)
all clean package install::
	git submodule update --init
	./framework/git-submodule-recur.sh init
	$(MAKE) $(MAKEFLAGS) MAKELEVEL=0 $@
else

LIBRARY_NAME = libapplist
libapplist_OBJC_FILES = ALApplicationList.x ALApplicationTableDataSource.m ALValueCell.m
libapplist_CFLAGS = -I./
libapplist_FRAMEWORKS = UIKit CoreGraphics QuartzCore
libapplist_LIBRARIES = MobileGestalt
libapplist_USE_MODULES = 0

BUNDLE_NAME = AppList
AppList_OBJC_FILES = ALApplicationPreferenceViewController.m
AppList_FRAMEWORKS = UIKit CoreGraphics
AppList_PRIVATE_FRAMEWORKS = Preferences
AppList_LDFLAGS = -L$(FW_OBJ_DIR)
AppList_LIBRARIES = applist
AppList_INSTALL_PATH = /System/Library/PreferenceBundles
AppList_USE_MODULES = 0


THEOS_PLATFORM_SDK_ROOT_armv6 = /Applications/Xcode_Legacy.app/Contents/Developer
ifneq ($(wildcard $(THEOS_PLATFORM_SDK_ROOT_armv6)/*),)
THEOS_PLATFORM_SDK_ROOT_armv7 = /Volumes/Xcode/Xcode.app/Contents/Developer
THEOS_PLATFORM_SDK_ROOT_armv7s = /Volumes/Xcode/Xcode.app/Contents/Developer
THEOS_PLATFORM_SDK_ROOT_arm64 = /Volumes/Xcode_9.4.1/Xcode.app/Contents/Developer
SDKVERSION_armv6 = 5.1
INCLUDE_SDKVERSION_armv6 = latest
TARGET_IPHONEOS_DEPLOYMENT_VERSION = 7.0
TARGET_IPHONEOS_DEPLOYMENT_VERSION_armv6 = 3.0
TARGET_IPHONEOS_DEPLOYMENT_VERSION_armv7 = 3.0
TARGET_IPHONEOS_DEPLOYMENT_VERSION_armv7s = 6.0
TARGET_IPHONEOS_DEPLOYMENT_VERSION_arm64 = 7.0
TARGET_IPHONEOS_DEPLOYMENT_VERSION_arm64e = 8.4
IPHONE_ARCHS = armv6 armv7 arm64 arm64e
libapplist_IPHONE_ARCHS = armv6 armv7 armv7s arm64 arm64e
else
TARGET_IPHONEOS_DEPLOYMENT_VERSION = 8.4
IPHONE_ARCHS = armv7 arm64 arm64e
libapplist_IPHONE_ARCHS = armv7 armv7s arm64 arm64e
ifeq ($(FINALPACKAGE),1)
$(error Building final package requires a legacy Xcode install!)
endif
endif

ifeq ($(THEOS_CURRENT_ARCH),armv6)
GO_EASY_ON_ME=1
endif

ADDITIONAL_CFLAGS = -Ipublic -Ioverlayheaders -I.

include framework/makefiles/common.mk
include framework/makefiles/library.mk
include framework/makefiles/bundle.mk

stage::
	mkdir -p $(THEOS_STAGING_DIR)/usr/include/AppList
	$(ECHO_NOTHING)rsync -a ./public/* $(THEOS_STAGING_DIR)/usr/include/AppList $(FW_RSYNC_EXCLUDES)$(ECHO_END)

endif
