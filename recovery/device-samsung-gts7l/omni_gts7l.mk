#
# Copyright 2016 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Sample: This is where we'd set a backup provider if we had one
# $(call inherit-product, device/sample/products/backup_overlay.mk)

# Inherit from the common Open Source product configuration
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_base_telephony.mk)

## Device identifier. This must come after all inclusions
PRODUCT_NAME := omni_gts7l
PRODUCT_DEVICE := gts7l
PRODUCT_MODEL := SM-T875
PRODUCT_BRAND := samsung
PRODUCT_MANUFACTURER := samsung
PRODUCT_GMS_CLIENTID_BASE := android-samsung

# Without this, BUILDING_RECOVERY_IMAGE never gets set on modern (Android
# 12-era) build/make, and the "recoveryimage" ninja target silently ends up
# an empty phony with zero dependencies ("ninja: no work to do") rather than
# an error. This is a PRODUCT_* variable, locked read-only by the time
# BoardConfig.mk is parsed, so it must be set here, not in BoardConfig.mk
# (cost real build-debugging time to find - see docs/twrp-build-notes.md).
PRODUCT_BUILD_RECOVERY_IMAGE := true
