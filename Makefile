ifeq ($(shell [ -f ./framework/makefiles/common.mk ] && echo 1 || echo 0),0)
all clean package install::
	git submodule update --init
	./framework/git-submodule-recur.sh init
	$(MAKE) $(MAKEFLAGS) MAKELEVEL=0 $@
else

LIBRARY_NAME = libapplist
libapplist_OBJC_FILES = ALApplicationList.m ALApplicationTableDataSource.m
libapplist_FRAMEWORKS = UIKit CoreGraphics
libapplist_PRIVATE_FRAMEWORKS = AppSupport ImageIO

BUNDLE_NAME = AppList
AppList_OBJC_FILES = ALApplicationPreferenceViewController.m
AppList_FRAMEWORKS = UIKit CoreGraphics
AppList_PRIVATE_FRAMEWORKS = Preferences
AppList_LDFLAGS = -L$(FW_OBJ_DIR) -lapplist
AppList_INSTALL_PATH = /System/Library/PreferenceBundles

include framework/makefiles/common.mk
include framework/makefiles/library.mk
include framework/makefiles/bundle.mk

endif
