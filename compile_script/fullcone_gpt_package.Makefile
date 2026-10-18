include $(TOPDIR)/rules.mk

PKG_NAME:=fullcone-target-gpt
PKG_VERSION:=2026.10.18
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)
PKG_FILE_DEPENDS:=$(CURDIR)/src

include $(INCLUDE_DIR)/package.mk

define Package/fullcone-target-gpt
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Checked x86 installation and sysupgrade GPT handling
  DEPENDS:=@TARGET_x86 +sgdisk
endef

define Package/fullcone-target-gpt/config
	source "$(SOURCE)/Config.in"
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) -std=gnu99 -Wall -Wextra -Werror $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/fullcone-target-gpt $(PKG_BUILD_DIR)/fullcone_upgrade_gpt.c
endef

define Package/fullcone-target-gpt/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/fullcone-target-gpt $(1)/usr/sbin/
	$(INSTALL_DIR) $(1)/usr/libexec/fullcone
	ln -sf /bin/busybox $(1)/usr/libexec/fullcone/busybox
endef

$(eval $(call BuildPackage,fullcone-target-gpt))
