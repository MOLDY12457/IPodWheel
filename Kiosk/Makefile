include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IPodWheelKiosk
IPodWheelKiosk_FILES = Tweak.m
IPodWheelKiosk_FRAMEWORKS = UIKit Foundation AudioToolbox
IPodWheelKiosk_CFLAGS = -fobjc-arc -Wno-arc-performSelector-leaks -Wno-deprecated-declarations
IPodWheelKiosk_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
