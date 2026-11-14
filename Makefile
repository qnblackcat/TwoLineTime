TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TwoLineTime

TwoLineTime_FILES = Tweak.x TLTSettings.m TLTRender.m TLTPill.m TLTFocus.m TLTLog.m
TwoLineTime_FRAMEWORKS = UIKit
TwoLineTime_CFLAGS = -fobjc-arc

SUBPROJECTS = prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
