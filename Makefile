export ARCHS = armv7
export TARGET = iphone:clang:9.3:6.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = IPodWheel
IPodWheel_FILES = main.m AppDelegate.m
IPodWheel_FRAMEWORKS = UIKit Foundation CoreGraphics MediaPlayer AudioToolbox AVFoundation
IPodWheel_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
IPodWheel_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/application.mk

# Tweak "ecran d'accueil" (mode kiosque) : livre dans le meme paquet
SUBPROJECTS += Kiosk
include $(THEOS_MAKE_PATH)/aggregate.mk

# relance SpringBoard pour charger le tweak et rafraichir l'icone
after-install::
	install.exec "killall -9 SpringBoard"
