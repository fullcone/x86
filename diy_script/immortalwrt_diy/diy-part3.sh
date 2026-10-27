#!/bin/bash
#
# Copyright (c) 2019-2025 SmallProgram <https://github.com/smallprogram>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/smallprogram/OpenWrtAction
# File name: diy-part3.sh
# Description: OpenWrt DIY script part 3
# This script will be executed after `make defconfig` and `make download` to fix certain issues.
#

attempts="${1:-1}"

# fullcone fail-fast diy-part3
set -euo pipefail

echo "DiY script part 3: is Runing"

echo "修正相关package的hash值"

# fullcone imported SmartDNS pinned sources
python3 "$GITHUB_WORKSPACE/compile_script/fullcone_smartdns.py" record

# -------------------------shadowsocksr-libev----------------------------------
# make package/feeds/passwall_packages/shadowsocksr-libev/download -j8
# make package/feeds/passwall_packages/shadowsocksr-libev/check FIXUP=1 V=s
# -------------------------end-shadowsocksr-libev----------------------------------
echo "修正完成"


echo "DiY script part 3: is Completed"

# set -e
# if [ $attempts -eq 3 ]; then
#   make -j$(nproc) V=s \
#     package/feeds/passwall/luci-app-passwall/compile \
#     package/feeds/passwall2/luci-app-passwall2/compile \
#     package/feeds/helloworld/luci-app-ssr-plus/compile \
#     package/feeds/OpenClash/luci-app-openclash/compile \
#     package/feeds/nikki/luci-app-nikki/compile \
#     package/custom_packages/luci-app-alpha-config/compile \
#     package/custom_packages/luci-app-argon-config/compile \
#     package/custom_packages/luci-app-bandix/luci-app-bandix/compile \
#     package/custom_packages/openwrt-bandix/openwrt-bandix/compile \
#     package/custom_packages/luci-app-kucat-config/compile \
#     package/custom_packages/luci-theme-alpha/compile \
#     package/custom_packages/luci-theme-alpha-reborn/compile \
#     package/custom_packages/luci-theme-argon/compile \
#     package/custom_packages/luci-theme-aurora/compile \
#     package/custom_packages/luci-theme-kucat/compile \
#     package/custom_packages/luci-theme-material3/compile \
#     package/custom_packages/mosdns/luci-app-mosdns/compile \
#     package/custom_packages/netspeedtest/luci-app-netspeedtest/compile
    
# else
#   make -j$(nproc) \
#     package/feeds/passwall/luci-app-passwall/compile \
#     package/feeds/passwall2/luci-app-passwall2/compile \
#     package/feeds/helloworld/luci-app-ssr-plus/compile \
#     package/feeds/OpenClash/luci-app-openclash/compile \
#     package/feeds/nikki/luci-app-nikki/compile \
#     package/custom_packages/luci-app-alpha-config/compile \
#     package/custom_packages/luci-app-argon-config/compile \
#     package/custom_packages/luci-app-bandix/luci-app-bandix/compile \
#     package/custom_packages/openwrt-bandix/openwrt-bandix/compile \
#     package/custom_packages/luci-app-kucat-config/compile \
#     package/custom_packages/luci-theme-alpha/compile \
#     package/custom_packages/luci-theme-alpha-reborn/compile \
#     package/custom_packages/luci-theme-argon/compile \
#     package/custom_packages/luci-theme-aurora/compile \
#     package/custom_packages/luci-theme-kucat/compile \
#     package/custom_packages/luci-theme-material3/compile \
#     package/custom_packages/mosdns/luci-app-mosdns/compile \
#     package/custom_packages/netspeedtest/luci-app-netspeedtest/compile
# fi

# echo "DiY script part 3: is Disabled"
# fullcone reliability 20261016
for source in feeds/* package/custom_packages/*; do
  [ ! -d "$source/.git" ] || printf '%s=%s\n' "$source" "$(git -C "$source" rev-parse HEAD)" >> source-versions.txt
done
