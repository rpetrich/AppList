ifeq ($(shell [ -f ./framework/makefiles/common.mk ] && echo 1 || echo 0),0)
all clean package install::
	git submodule update --init
	./framework/git-submodule-recur.sh init
	$(MAKE) $(MAKEFLAGS) MAKELEVEL=0 $@
else

LIBRARY_NAME = libapplist
libapplist_OBJC_FILES = ALApplicationList.m ALApplicationTableDataSource.m ALValueCell.m
libapplist_CFLAGS = -I./
libapplist_FRAMEWORKS = UIKit CoreGraphics QuartzCore
libapplist_PRIVATE_FRAMEWORKS = AppSupport
libapplist_LIBRARIES = MobileGestalt
libapplist_IPHONE_ARCHS = armv6 armv7 armv7s arm64

BUNDLE_NAME = AppList
AppList_OBJC_FILES = ALApplicationPreferenceViewController.m
AppList_FRAMEWORKS = UIKit CoreGraphics
AppList_PRIVATE_FRAMEWORKS = Preferences
AppList_LDFLAGS = -L$(FW_OBJ_DIR)
AppList_LIBRARIES = applist
AppList_INSTALL_PATH = /System/Library/PreferenceBundles

TARGET_IPHONEOS_DEPLOYMENT_VERSION := 3.0

IPHONE_ARCHS = armv6 armv7 arm64

SDKVERSION_armv6 = 5.1
INCLUDE_SDKVERSION_armv6 = 7.1
THEOS_PLATFORM_SDK_ROOT_armv6 = /Applications/Xcode_Legacy.app/Contents/Developer
ADDITIONAL_CFLAGS = -Ipublic

include framework/makefiles/common.mk
include framework/makefiles/library.mk
include framework/makefiles/bundle.mk

stage::
	mkdir -p $(THEOS_STAGING_DIR)/usr/include/AppList
	$(ECHO_NOTHING)rsync -a ./public/* $(THEOS_STAGING_DIR)/usr/include/AppList $(FW_RSYNC_EXCLUDES)$(ECHO_END)

endif
