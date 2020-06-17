ARCHS = arm64 arm64e

# SDKVERSION = 8.1
# SYSROOT = $(THEOS)/sdks/iPhoneOS8.1.sdk

include $(THEOS)/makefiles/common.mk

Purge95_LDFLAGS = -v -miphoneos-version-min=9.0
Purge95_CFLAGS =  -miphoneos-version-min=9.0 -v
Purge95_FRAMEWORKS =  IOKit
# sjbkjasbd_CFLAGS =  -Wno-unused-variable

TWEAK_NAME = Purge95
Purge95_FILES = Purge95.xm

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 UserEventAgent"
