LOCAL_PATH := $(call my-dir)

ifneq ($(filter gts7l, $(TARGET_DEVICE)),)

include $(call all-makefiles-under,$(LOCAL_PATH))

endif
