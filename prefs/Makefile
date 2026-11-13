include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = TwoLineTimePrefs

# The tweak's version, from the control file
TLT_VERSION := $(shell awk '/^Version:/ {print $$2}' ../control)

TwoLineTimePrefs_FILES = TLTRootListController.m ../TLTLog.m
TwoLineTimePrefs_FRAMEWORKS = UIKit
TwoLineTimePrefs_PRIVATE_FRAMEWORKS = Preferences
TwoLineTimePrefs_INSTALL_PATH = /Library/PreferenceBundles
TwoLineTimePrefs_CFLAGS = -fobjc-arc -DTLT_VERSION=\"$(TLT_VERSION)\"

include $(THEOS_MAKE_PATH)/bundle.mk
