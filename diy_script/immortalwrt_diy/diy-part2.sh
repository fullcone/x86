#!/bin/bash
#
# Copyright (c) 2019-2025 SmallProgram <https://github.com/smallprogram>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/smallprogram/OpenWrtAction
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# Add patches
if [ "$GITHUB_ACTIONS" = "true" ] && [ -n "$GITHUB_RUN_ID" ] && [ -n "$GITHUB_WORKFLOW" ]; then
    PATCHES_SRC_DIR="$GITHUB_WORKSPACE"
else
    PATCHES_SRC_DIR="../OpenWrtAction"
fi


#------------------------------------------------------移植包------------------------------------------------------------
# rm -rf temp_resp
# git clone -b master --single-branch https://github.com/openwrt/packages.git temp_resp/openwrt_packages

# # =========================================================
# # Golang/Rust 强制覆盖 (直接操作 feeds 目录)
# # 确保这段代码在 ./scripts/feeds update -a 之后执行
# # =========================================================
# echo "清理旧版 Golang 和 Rust..."
# # 1. 删除 feeds 里的原生目录
# rm -rf feeds/packages/lang/golang
# rm -rf feeds/packages/lang/rust

# # 2. 如果之前执行过 feeds install，必须清理掉残留的软链接，防止指向空目录
# rm -rf package/feeds/packages/golang
# rm -rf package/feeds/packages/rust

# echo "注入最新版 Golang 和 Rust..."
# # 3. 将新代码直接放入 feeds 目录，伪装成原生 feed 包
# cp -a temp_resp/openwrt_packages/lang/golang feeds/packages/lang/
# cp -a temp_resp/openwrt_packages/lang/rust feeds/packages/lang/

# # =========================================================
# # 恢复上游时间戳 (避免不必要的重新编译)
# # =========================================================
# GOLANG_TIME=$(cd temp_resp/openwrt_packages && git log -1 --format=%cd --date=unix -- lang/golang)
# RUST_TIME=$(cd temp_resp/openwrt_packages && git log -1 --format=%cd --date=unix -- lang/rust)

# if [ -n "$GOLANG_TIME" ]; then
#     find feeds/packages/lang/golang -exec touch -m -d @"$GOLANG_TIME" {} +
# else
#     echo "⚠️ 警告: 无法提取 Golang 的上游时间戳，将使用拷贝时的时间"
# fi

# if [ -n "$RUST_TIME" ]; then
#     find feeds/packages/lang/rust -exec touch -m -d @"$RUST_TIME" {} +
# else
#     echo "⚠️ 警告: 无法提取 Rust 的上游时间戳，将使用拷贝时的时间"
# fi
# rm -rf temp_resp

#-------------------------------------------------------end 移植包--------------------------------------------------------


#-----------------------------------------------修改脚本------------------------------------------------------------

# rm appfilter
rm -rf ./feeds/packages/net/open-app-filter

# fullcone nikki mihomo conflict compatibility
nikki_alpha_makefile="feeds/nikki/mihomo-alpha/Makefile"
nikki_meta_makefile="feeds/nikki/mihomo-meta/Makefile"

for makefile in "$nikki_alpha_makefile" "$nikki_meta_makefile"; do
    test -f "$makefile" || {
        echo "Missing Nikki package definition: $makefile"
        exit 1
    }
done

if grep -qE '^[[:space:]]*CONFLICTS:=mihomo-meta[[:space:]]*$' "$nikki_alpha_makefile" \
    && grep -qE '^[[:space:]]*CONFLICTS:=mihomo-alpha[[:space:]]*$' "$nikki_meta_makefile"; then
    sed -i '/^[[:space:]]*CONFLICTS:=mihomo-alpha[[:space:]]*$/d' "$nikki_meta_makefile"
    echo "Removed redundant mihomo-meta -> mihomo-alpha conflict"
fi

if grep -qE '^[[:space:]]*CONFLICTS:=mihomo-meta[[:space:]]*$' "$nikki_alpha_makefile" \
    && grep -qE '^[[:space:]]*CONFLICTS:=mihomo-alpha[[:space:]]*$' "$nikki_meta_makefile"; then
    echo "Nikki mihomo packages still contain a recursive conflict"
    exit 1
fi

# Modify default IP
sed -i 's/192.168.1.1/172.16.0.253/g' package/base-files/files/bin/config_generate

# fixed rust host build download llvm in ci error
# sed -i 's/--set=llvm\.download-ci-llvm=true/--set=llvm.download-ci-llvm=false/' package/custom_overrides/rust/Makefile
# grep -q -- '--ci false \\' package/custom_overrides/rust/Makefile || sed -i '/x\.py \\/a \        --ci false \\' package/custom_overrides/rust/Makefile

# inject download package
mkdir -p dl
cp -r $PATCHES_SRC_DIR/library/* ./dl/


# --- Modify SSH Configuration (Dropbear -> 2222, OpenSSH -> 22) ---

# 1. 确保 files 目录存在 (在 OpenWrt 源码根目录下)
mkdir -p files/etc/uci-defaults

# 2. 生成首次启动脚本
cat << 'EOF' > files/etc/uci-defaults/99-custom-ssh-config
#!/bin/sh

# --- 1. 停止服务 ---
# 先停掉 Dropbear，确保它彻底释放 22 端口
# (在首次启动脚本中执行这步是安全的，不会导致用户掉线，因为此时还没人登录)
/etc/init.d/dropbear stop
/etc/init.d/sshd stop 2>/dev/null  # 加上这句以防万一 sshd 已经尝试自启

# --- 2. 配置 Dropbear (UCI) ---
# 将 Dropbear 端口移至 2222
uci set dropbear.@dropbear[0].Port='2222'
uci commit dropbear

# --- 3. 配置 OpenSSH (sshd_config) ---
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    # 允许 Root 登录
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
    # 显式指定端口 22
    sed -i 's/^#*Port.*/Port 22/' "$SSHD_CONFIG"
fi

# --- 4. 同步密钥 (可选) ---
# mkdir -p /root/.ssh
# if [ ! -L /root/.ssh/authorized_keys ]; then
#     [ -f /root/.ssh/authorized_keys ] && mv /root/.ssh/authorized_keys /root/.ssh/authorized_keys.bak
#     ln -s /etc/dropbear/authorized_keys /root/.ssh/authorized_keys
# fi

# --- 5. 按顺序启动服务 ---

# 第一步：启动 Dropbear
# 此时配置已生效，它会乖乖去占 2222，绝对不会碰 22
/etc/init.d/dropbear start

# 第二步：启动 OpenSSH
# 此时 22 端口绝对是空闲的，OpenSSH 可以顺利接管
/etc/init.d/sshd enable
/etc/init.d/sshd start

exit 0
EOF

# 3. 赋予脚本执行权限
chmod +x files/etc/uci-defaults/99-custom-ssh-config

# --- End Modify SSH Configuration ---
#------------------------------------------------end 修改脚本-------------------------------------------------------


echo "DIY2 is complate!"
# Add QEMU bridge config
mkdir -p files/etc/qemu
echo "allow br-lan" > files/etc/qemu/bridge.conf

# fullcone ghfu default repo
GHFU_DEFAULT_REPO="fullcone/x86"
for ghfu_dir in \
    feeds/ghfu/luci-app-ghfu \
    feeds/luci/applications/luci-app-ghfu \
    package/feeds/ghfu/luci-app-ghfu \
    package/feeds/luci/luci-app-ghfu
do
    if [ -d "$ghfu_dir" ]; then
        echo "Patch luci-app-ghfu default repo in $ghfu_dir"
        find "$ghfu_dir" -type f -exec sed -i "s|smallprogram/OpenWrtAction|${GHFU_DEFAULT_REPO}|g" {} +
    fi
done

mkdir -p files/etc/config files/etc/uci-defaults
cat > files/etc/config/ghfu <<EOF
config ghfu 'main'
    option github_repo '${GHFU_DEFAULT_REPO}'
    option selected_release ''
    option keep_config '1'
    option fetch_timeout '15'
    option filter_ext_enabled '1'
    option valid_extensions '.img .img.gz .bin .tar .itb .trx .chk .dlf .ari'
EOF

cat > files/etc/uci-defaults/99-ghfu-default-repo <<EOF
#!/bin/sh

uci set ghfu.main.github_repo='${GHFU_DEFAULT_REPO}'
uci commit ghfu

exit 0
EOF
chmod +x files/etc/uci-defaults/99-ghfu-default-repo

# fullcone network setup wizard
mkdir -p files/usr/bin files/etc/uci-defaults

cat > files/usr/bin/fullcone-netsetup <<'EOF'
#!/bin/sh

ROOT_HASH='$5$GLPc3wj20eD45Gfu$O1HswgZ86PSSAYRCTk.VaiT.3vfGK/32IxNlCycZa04'
DEFAULT_PASSWORD='backerhacK123'

pause() {
    printf '\nPress Enter to continue...'
    read -r _
}

clean_input() {
    printf '%s' "$1" | tr -d '\011\015' | tr -cd '[:print:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

current_or_default() {
    local key="$1"
    local default="$2"
    local value
    value="$(uci -q get "$key" 2>/dev/null || true)"
    [ -n "$value" ] && printf '%s' "$value" || printf '%s' "$default"
}

prompt() {
    local var="$1"
    local label="$2"
    local default="$3"
    local value
    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$label" "$default"
    else
        printf '%s: ' "$label"
    fi
    read -r value
    value="$(clean_input "$value")"
    [ -z "$value" ] && value="$default"
    eval "$var=\"\$value\""
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_vlan_id() {
    is_uint "$1" || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 4094 ]
}

is_metric() {
    is_uint "$1" || return 1
    [ "$1" -ge 0 ] && [ "$1" -le 4294967295 ]
}

is_wan2_mode() {
    case "$1" in
        0|1|2|3|4) return 0 ;;
        *) return 1 ;;
    esac
}

prompt_validated() {
    local var="$1"
    local label="$2"
    local default="$3"
    local validator="$4"
    local hint="$5"
    local value

    while :; do
        prompt value "$label" "$default"
        if "$validator" "$value"; then
            eval "$var=\"\$value\""
            return 0
        fi
        echo "Invalid value: $value"
        echo "$hint"
    done
}

vlan_default() {
    local key="$1"
    local fallback="$2"
    local value
    value="$(current_or_default "$key" "$fallback")"
    value="${value##*.}"
    is_vlan_id "$value" && printf '%s' "$value" || printf '%s' "$fallback"
}

ipv4_addr_default() {
    local key="$1"
    local fallback="$2"
    local value
    value="$(current_or_default "$key" "$fallback")"
    value="${value%%/*}"
    printf '%s' "$value"
}

yesno() {
    local label="$1"
    local default="$2"
    local value
    printf '%s [%s]: ' "$label" "$default"
    read -r value
    value="$(clean_input "$value")"
    [ -z "$value" ] && value="$default"
    case "$value" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

device_section_by_name() {
    local name="$1"
    local section
    for section in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^=]*\)=device$/\1/p"); do
        [ "$(uci -q get network."$section".name 2>/dev/null)" = "$name" ] && {
            printf '%s' "$section"
            return 0
        }
    done
    return 1
}

bridge_first_port() {
    local bridge="$1"
    local default="$2"
    local section ports first
    section="$(device_section_by_name "$bridge" || true)"
    if [ -n "$section" ]; then
        ports="$(uci -q get network."$section".ports 2>/dev/null || true)"
        set -- $ports
        first="$1"
    fi
    [ -n "$first" ] && printf '%s' "$first" || printf '%s' "$default"
}

zone_section_by_name() {
    local name="$1"
    local section
    for section in $(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^=]*\)=zone$/\1/p"); do
        [ "$(uci -q get firewall."$section".name 2>/dev/null)" = "$name" ] && {
            printf '%s' "$section"
            return 0
        }
    done
    return 1
}

ensure_vlan_device_for_port() {
    local port="$1"
    local section parent vid

    case "$port" in
        *.*) ;;
        *) return 0 ;;
    esac

    parent="${port%%.*}"
    vid="${port##*.}"
    is_vlan_id "$vid" || {
        echo "Invalid VLAN port: $port"
        return 1
    }

    section="$(device_section_by_name "$port" || true)"
    if [ -z "$section" ]; then
        section="$(uci add network device)"
    fi

    uci set network."$section".name="$port"
    uci set network."$section".type='8021q'
    uci set network."$section".ifname="$parent"
    uci set network."$section".vid="$vid"
}

ensure_bridge_device() {
    local bridge="$1"
    local port="$2"
    local section
    ensure_vlan_device_for_port "$port"
    section="$(device_section_by_name "$bridge" || true)"
    if [ -z "$section" ]; then
        section="$(uci add network device)"
    fi
    uci set network."$section".name="$bridge"
    uci set network."$section".type='bridge'
    uci -q delete network."$section".ports
    uci add_list network."$section".ports="$port"
}

ensure_zone_network() {
    local zone="$1"
    local network="$2"
    local section
    section="$(zone_section_by_name "$zone" || true)"
    if [ -z "$section" ]; then
        section="$(uci add firewall zone)"
        uci set firewall."$section".name="$zone"
        uci set firewall."$section".output='ACCEPT'
    fi
    uci -q del_list firewall."$section".network="$network"
    uci add_list firewall."$section".network="$network"
}

delete_firewall_rule_by_name() {
    local name="$1"
    local section
    while :; do
        section="$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@rule\[[0-9]*\]\)\.name='$name'$/\1/p" | head -n 1)"
        [ -n "$section" ] || break
        uci -q delete firewall."$section"
    done
}

set_root_password() {
    if [ -f /etc/shadow ]; then
        sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" /etc/shadow
    fi
}

open_management_access() {
    local ssh_rule web_rule

    if ! uci -q get dropbear.@dropbear[0] >/dev/null 2>&1; then
        uci add dropbear dropbear >/dev/null
    fi
    uci -q delete dropbear.@dropbear[0].Interface
    uci set dropbear.@dropbear[0].PasswordAuth='on'
    uci set dropbear.@dropbear[0].RootPasswordAuth='on'
    uci commit dropbear

    if uci -q get uhttpd.main >/dev/null 2>&1; then
        uci -q delete uhttpd.main.listen_http
        uci -q delete uhttpd.main.listen_https
        uci add_list uhttpd.main.listen_http='0.0.0.0:80'
        uci add_list uhttpd.main.listen_http='[::]:80'
        uci add_list uhttpd.main.listen_https='0.0.0.0:443'
        uci add_list uhttpd.main.listen_https='[::]:443'
        uci commit uhttpd
    fi

    ensure_zone_network lan lan
    ensure_zone_network wan wan
    ensure_zone_network wan wan6
    ensure_zone_network wan wan1
    ensure_zone_network wan wan2
    ensure_zone_network wan wan2_1226
    ensure_zone_network wan wan2_1227

    delete_firewall_rule_by_name 'Allow-SSH-from-Any-Zone'
    ssh_rule="$(uci add firewall rule)"
    uci set firewall."$ssh_rule".name='Allow-SSH-from-Any-Zone'
    uci set firewall."$ssh_rule".src='*'
    uci set firewall."$ssh_rule".proto='tcp'
    uci set firewall."$ssh_rule".dest_port='22 2222'
    uci set firewall."$ssh_rule".target='ACCEPT'

    delete_firewall_rule_by_name 'Allow-Web-from-Any-Zone'
    web_rule="$(uci add firewall rule)"
    uci set firewall."$web_rule".name='Allow-Web-from-Any-Zone'
    uci set firewall."$web_rule".src='*'
    uci set firewall."$web_rule".proto='tcp'
    uci set firewall."$web_rule".dest_port='80 443'
    uci set firewall."$web_rule".target='ACCEPT'

    uci commit firewall

    /etc/init.d/dropbear restart 2>/dev/null || true
    /etc/init.d/sshd restart 2>/dev/null || true
    /etc/init.d/uhttpd restart 2>/dev/null || true
    /etc/init.d/firewall restart 2>/dev/null || true
}

apply_default_access() {
    set_root_password
    open_management_access
}

show_interfaces() {
    echo
    echo 'Network interfaces:'
    for iface in $(ls /sys/class/net 2>/dev/null | sort); do
        case "$iface" in
            lo|br-*|docker*|dummy*|ifb*|pppoe-*|gre*|gretap*|erspan*|ip6gre*|sit*|tun*|tap*) continue ;;
        esac
        mac="$(cat /sys/class/net/"$iface"/address 2>/dev/null || true)"
        state="$(cat /sys/class/net/"$iface"/operstate 2>/dev/null || true)"
        printf "  %-10s %-17s %s\n" "$iface" "$mac" "$state"
    done
    echo
}

show_status() {
    clear
    echo '================ FullCone OpenWrt Status ================'
    echo
    ip -br addr 2>/dev/null || ip addr
    echo
    echo 'Routes:'
    ip route show
    echo
    echo 'Firewall management rules:'
    uci show firewall 2>/dev/null | grep -E 'Allow-(SSH|Web)-from-Any-Zone|dest_port|src=' || true
}

network_wizard() {
    local lan_dev lan_ip lan_mask
    local wan1_dev wan1_ip wan1_mask wan1_gw wan1_dns wan1_metric
    local wan2_mode wan2_dev wan2_ip wan2_mask wan2_gw wan2_dns wan2_metric
    local ppp_dev vlan1 user1 pass1 metric1 vlan2 user2 pass2 metric2
    local wan2_section wan2_section1 wan2_section2 wan2_zone_networks

    clear
    echo '================ FullCone Network Setup ================'
    show_interfaces
    echo 'This wizard will overwrite LAN/WAN UCI network settings.'
    echo 'Current SSH may disconnect after network restart.'
    echo 'Interface input accepts a physical NIC like eth2 or a VLAN like eth2.1999.'
    echo

    prompt lan_dev 'LAN interface' "$(bridge_first_port br-lan eth2.1999)"
    prompt lan_ip 'LAN IPv4 address' "$(ipv4_addr_default network.lan.ipaddr 172.16.101.253)"
    prompt lan_mask 'LAN netmask' "$(current_or_default network.lan.netmask 255.255.255.0)"

    if yesno 'Configure WAN1 static IPv4' 'y'; then
        prompt wan1_dev 'WAN1 interface' "$(current_or_default network.wan1.device eth2)"
        prompt wan1_ip 'WAN1 IPv4 address' "$(ipv4_addr_default network.wan1.ipaddr 172.16.0.40)"
        prompt wan1_mask 'WAN1 netmask' "$(current_or_default network.wan1.netmask 255.255.255.0)"
        prompt wan1_gw 'WAN1 gateway' "$(current_or_default network.wan1.gateway 172.16.0.254)"
        prompt wan1_dns 'WAN1 DNS servers' "$(current_or_default network.wan1.dns '223.5.5.5 119.29.29.29')"
        prompt_validated wan1_metric 'WAN1 route metric' "$(current_or_default network.wan1.metric 10)" is_metric 'Use a non-negative integer metric.'
    fi

    echo
    echo 'WAN2 mode:'
    echo '  0) skip WAN2'
    echo '  1) static IPv4 on physical interface'
    echo '  2) PPPoE on physical interface'
    echo '  3) PPPoE on one VLAN, for example eth3.1226'
    echo '  4) PPPoE on two VLANs, for example eth3.1226 and eth3.1227'
    prompt_validated wan2_mode 'WAN2 mode' '4' is_wan2_mode 'Use 0, 1, 2, 3, or 4.'
    case "$wan2_mode" in
        1)
            prompt wan2_dev 'WAN2 interface' "$(current_or_default network.wan2.device eth3)"
            prompt wan2_ip 'WAN2 IPv4 address' "$(current_or_default network.wan2.ipaddr '')"
            prompt wan2_mask 'WAN2 netmask' "$(current_or_default network.wan2.netmask 255.255.255.0)"
            prompt wan2_gw 'WAN2 gateway' "$(current_or_default network.wan2.gateway '')"
            prompt wan2_dns 'WAN2 DNS servers' "$(current_or_default network.wan2.dns '223.5.5.5 119.29.29.29')"
            prompt_validated wan2_metric 'WAN2 route metric' "$(current_or_default network.wan2.metric 20)" is_metric 'Use a non-negative integer metric.'
            ;;
        2)
            prompt ppp_dev 'WAN2 physical interface' "$(current_or_default network.wan2.device eth3)"
            prompt user1 'WAN2 PPPoE username' "$(current_or_default network.wan2.username '')"
            printf 'WAN2 PPPoE password [leave blank to keep existing]: '
            read -r pass1
            pass1="$(clean_input "$pass1")"
            prompt_validated metric1 'WAN2 PPPoE route metric' "$(current_or_default network.wan2.metric 20)" is_metric 'Use a non-negative integer metric.'
            ;;
        3)
            prompt ppp_dev 'WAN2 physical interface' eth3
            prompt_validated vlan1 'WAN2 VLAN ID' "$(vlan_default network.wan2_1226.device 1226)" is_vlan_id 'Use a VLAN ID from 1 to 4094.'
            wan2_section="wan2_${vlan1}"
            prompt user1 'WAN2 PPPoE username' "$(current_or_default network."$wan2_section".username '')"
            printf 'WAN2 PPPoE password [leave blank to keep existing]: '
            read -r pass1
            pass1="$(clean_input "$pass1")"
            prompt_validated metric1 'WAN2 PPPoE route metric' "$(current_or_default network."$wan2_section".metric 20)" is_metric 'Use a non-negative integer metric.'
            ;;
        4)
            prompt ppp_dev 'WAN2 physical interface' eth3
            prompt_validated vlan1 'First VLAN ID' "$(vlan_default network.wan2_1226.device 1226)" is_vlan_id 'Use a VLAN ID from 1 to 4094.'
            wan2_section1="wan2_${vlan1}"
            prompt user1 'First PPPoE username' "$(current_or_default network."$wan2_section1".username "$(current_or_default network.wan2_1226.username '')")"
            printf 'First PPPoE password [leave blank to keep existing]: '
            read -r pass1
            pass1="$(clean_input "$pass1")"
            prompt_validated metric1 'First PPPoE route metric' "$(current_or_default network."$wan2_section1".metric "$(current_or_default network.wan2_1226.metric 20)")" is_metric 'Use a non-negative integer metric.'
            prompt_validated vlan2 'Second VLAN ID' "$(vlan_default network.wan2_1227.device 1227)" is_vlan_id 'Use a VLAN ID from 1 to 4094.'
            wan2_section2="wan2_${vlan2}"
            prompt user2 'Second PPPoE username' "$(current_or_default network."$wan2_section2".username "$(current_or_default network.wan2_1227.username '')")"
            printf 'Second PPPoE password [leave blank to keep existing]: '
            read -r pass2
            pass2="$(clean_input "$pass2")"
            prompt_validated metric2 'Second PPPoE route metric' "$(current_or_default network."$wan2_section2".metric "$(current_or_default network.wan2_1227.metric 30)")" is_metric 'Use a non-negative integer metric.'
            ;;
        0|'')
            ;;
        *)
            echo 'Invalid WAN2 mode, skipping WAN2.'
            wan2_mode=0
            ;;
    esac

    echo
    echo 'About to apply network settings.'
    yesno 'Apply now' 'n' || return 0

    cp /etc/config/network "/etc/config/network.bak.$(date +%s)" 2>/dev/null || true
    cp /etc/config/firewall "/etc/config/firewall.bak.$(date +%s)" 2>/dev/null || true

    ensure_bridge_device br-lan "$lan_dev"
    uci set network.lan='interface'
    uci set network.lan.device='br-lan'
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$lan_ip"
    uci set network.lan.netmask="$lan_mask"
    uci set network.lan.ip6assign='60'

    uci -q delete network.wan
    uci -q delete network.wan6
    uci -q delete network.wan2
    uci -q delete network.wan2_vlan
    uci -q delete network.wan2_1226
    uci -q delete network.wan2_1227

    if [ -n "${wan1_dev:-}" ]; then
        ensure_vlan_device_for_port "$wan1_dev"
        uci set network.wan1='interface'
        uci set network.wan1.device="$wan1_dev"
        uci set network.wan1.proto='static'
        uci set network.wan1.ipaddr="$wan1_ip"
        uci set network.wan1.netmask="$wan1_mask"
        uci set network.wan1.gateway="$wan1_gw"
        uci set network.wan1.dns="$wan1_dns"
        uci set network.wan1.metric="$wan1_metric"
    fi

    wan2_zone_networks=""
    case "$wan2_mode" in
        1)
            uci set network.wan2='interface'
            ensure_vlan_device_for_port "$wan2_dev"
            uci set network.wan2.device="$wan2_dev"
            uci set network.wan2.proto='static'
            uci set network.wan2.ipaddr="$wan2_ip"
            uci set network.wan2.netmask="$wan2_mask"
            [ -n "$wan2_gw" ] && uci set network.wan2.gateway="$wan2_gw"
            [ -n "$wan2_dns" ] && uci set network.wan2.dns="$wan2_dns"
            uci set network.wan2.metric="$wan2_metric"
            wan2_zone_networks="wan2"
            ;;
        2)
            uci set network.wan2='interface'
            ensure_vlan_device_for_port "$ppp_dev"
            uci set network.wan2.device="$ppp_dev"
            uci set network.wan2.proto='pppoe'
            uci set network.wan2.username="$user1"
            [ -n "$pass1" ] && uci set network.wan2.password="$pass1"
            uci set network.wan2.metric="$metric1"
            uci set network.wan2.ipv6='auto'
            wan2_zone_networks="wan2"
            ;;
        3)
            wan2_section="wan2_${vlan1}"
            ensure_vlan_device_for_port "${ppp_dev}.${vlan1}"
            uci -q delete network."$wan2_section"
            uci set network."$wan2_section"='interface'
            uci set network."$wan2_section".device="${ppp_dev}.${vlan1}"
            uci set network."$wan2_section".proto='pppoe'
            uci set network."$wan2_section".username="$user1"
            [ -n "$pass1" ] && uci set network."$wan2_section".password="$pass1"
            uci set network."$wan2_section".metric="$metric1"
            uci set network."$wan2_section".ipv6='auto'
            wan2_zone_networks="$wan2_section"
            ;;
        4)
            wan2_section1="wan2_${vlan1}"
            wan2_section2="wan2_${vlan2}"
            ensure_vlan_device_for_port "${ppp_dev}.${vlan1}"
            ensure_vlan_device_for_port "${ppp_dev}.${vlan2}"
            uci -q delete network."$wan2_section1"
            uci -q delete network."$wan2_section2"
            uci set network."$wan2_section1"='interface'
            uci set network."$wan2_section1".device="${ppp_dev}.${vlan1}"
            uci set network."$wan2_section1".proto='pppoe'
            uci set network."$wan2_section1".username="$user1"
            [ -n "$pass1" ] && uci set network."$wan2_section1".password="$pass1"
            uci set network."$wan2_section1".metric="$metric1"
            uci set network."$wan2_section1".ipv6='auto'

            uci set network."$wan2_section2"='interface'
            uci set network."$wan2_section2".device="${ppp_dev}.${vlan2}"
            uci set network."$wan2_section2".proto='pppoe'
            uci set network."$wan2_section2".username="$user2"
            [ -n "$pass2" ] && uci set network."$wan2_section2".password="$pass2"
            uci set network."$wan2_section2".metric="$metric2"
            uci set network."$wan2_section2".ipv6='auto'
            wan2_zone_networks="$wan2_section1 $wan2_section2"
            ;;
    esac

    ensure_zone_network lan lan
    ensure_zone_network wan wan1
    for zone_net in $wan2_zone_networks; do
        ensure_zone_network wan "$zone_net"
    done

    uci commit network
    open_management_access
    /etc/init.d/network restart

    echo
    echo 'Applied. Reconnect using the new address if SSH dropped.'
    pause
}

main_menu() {
    while :; do
        clear
        echo '================ FullCone OpenWrt Setup ================'
        echo "Default root password target: ${DEFAULT_PASSWORD}"
        echo
        echo '1) Configure LAN/WAN interactively'
        echo '2) Open SSH/Web from any LAN/WAN zone'
        echo '3) Reset root password to default'
        echo '4) Apply default access policy now'
        echo '5) Show network/firewall status'
        echo 'q) Quit'
        echo
        printf 'Select> '
        read -r choice
        choice="$(clean_input "$choice")"
        case "$choice" in
            1) network_wizard ;;
            2) open_management_access; echo 'SSH/Web access policy applied.'; pause ;;
            3) set_root_password; echo "Root password reset to ${DEFAULT_PASSWORD}."; pause ;;
            4) apply_default_access; echo 'Default password and access policy applied.'; pause ;;
            5) show_status; pause ;;
            q|Q) exit 0 ;;
        esac
    done
}

case "${1:-}" in
    --default-access)
        apply_default_access
        ;;
    *)
        main_menu
        ;;
esac
EOF
chmod +x files/usr/bin/fullcone-netsetup

cat > files/etc/uci-defaults/98-fullcone-default-access <<'EOF'
#!/bin/sh

/usr/bin/fullcone-netsetup --default-access >/tmp/fullcone-default-access.log 2>&1 || true

exit 0
EOF
chmod +x files/etc/uci-defaults/98-fullcone-default-access

# fullcone mdadm RAID-aware sysupgrade
python3 - <<'PY'
from pathlib import Path
import re

path = Path("target/linux/x86/base-files/lib/upgrade/platform.sh")
if not path.exists():
    raise SystemExit(f"missing x86 platform upgrade script: {path}")

text = path.read_text(encoding="utf-8")
marker = "# fullcone mdadm RAID-aware sysupgrade"
if marker in text:
    raise SystemExit(0)

for name in ("platform_check_image", "platform_copy_config", "platform_do_upgrade"):
    pattern = re.compile(rf"(^|\n){name}\(\)\s*\{{", re.M)
    text, count = pattern.subn(lambda m, n=name: f"{m.group(1)}{n}_stock() {{", text, count=1)
    if count != 1:
        raise SystemExit(f"failed to wrap {name} in {path}")

addon = r'''

# fullcone mdadm RAID-aware sysupgrade
RAMFS_COPY_BIN="${RAMFS_COPY_BIN:+$RAMFS_COPY_BIN }mdadm blkid e2fsck resize2fs cpio gzip"

fullcone_mdraid_root_dev() {
    local rootdev

    if grep -qw 'root=/dev/md/openwrt-root' /proc/cmdline 2>/dev/null; then
        echo /dev/md/openwrt-root
        return 0
    fi

    rootdev="$(awk '$2 == "/" && $1 ~ /^\/dev\/md/ { print $1; exit }' /proc/mounts 2>/dev/null)"
    [ -n "$rootdev" ] && { echo "$rootdev"; return 0; }

    [ -b /dev/md/openwrt-root ] && { echo /dev/md/openwrt-root; return 0; }
    return 1
}

fullcone_is_mdraid_root() {
    fullcone_mdraid_root_dev >/dev/null 2>&1
}

fullcone_md_block_name() {
    local mddev="$1"
    local real

    real="$(readlink -f "$mddev" 2>/dev/null || echo "$mddev")"
    real="${real##*/}"
    [ -n "$real" ] && [ -d "/sys/class/block/$real" ] && { echo "$real"; return 0; }
    return 1
}

fullcone_mdraid_members() {
    local mddev="$1"
    local mdname slave dev

    mdname="$(fullcone_md_block_name "$mddev" 2>/dev/null || true)"
    if [ -n "$mdname" ]; then
        for slave in /sys/class/block/"$mdname"/slaves/*; do
            [ -e "$slave" ] || continue
            dev="/dev/${slave##*/}"
            [ -b "$dev" ] && echo "$dev"
        done
        return 0
    fi

    mdadm --detail "$mddev" 2>/dev/null | awk '/\/dev\// { print $NF }'
}

fullcone_parent_disk_from_part() {
    local part="$1"
    local base="${part##*/}"

    case "$base" in
        nvme*n[0-9]p[0-9]*|mmcblk[0-9]*p[0-9]*)
            echo "/dev/${base%p[0-9]*}"
            ;;
        *[0-9])
            echo "/dev/${base%%[0-9]*}"
            ;;
        *)
            return 1
            ;;
    esac
}

fullcone_part_dev() {
    local disk="$1"
    local part="$2"
    local base="${disk##*/}"

    case "$base" in
        nvme*n[0-9]|mmcblk[0-9]*)
            echo "${disk}p${part}"
            ;;
        *)
            echo "${disk}${part}"
            ;;
    esac
}

fullcone_mdraid_boot_parts() {
    local mddev="$1"
    local member disk boot seen

    seen=" "
    for member in $(fullcone_mdraid_members "$mddev"); do
        disk="$(fullcone_parent_disk_from_part "$member" 2>/dev/null || true)"
        [ -n "$disk" ] || continue
        boot="$(fullcone_part_dev "$disk" 1)"
        [ -b "$boot" ] || continue
        case "$seen" in
            *" $boot "*) ;;
            *)
                seen="${seen}${boot} "
                echo "$boot"
                ;;
        esac
    done
}

fullcone_prepare_image_partmap() {
    local image="$1"

    rm -f /tmp/fullcone-image.bs /tmp/partmap.image
    v "Extract boot sector from the image"
    get_image_dd "$image" of=/tmp/fullcone-image.bs count=63 bs=512b || return 1
    get_partitions /tmp/fullcone-image.bs image || return 1
    rm -f /tmp/fullcone-image.bs
    grep -q '^1[[:space:]]' /tmp/partmap.image || return 1
    grep -q '^2[[:space:]]' /tmp/partmap.image || return 1
}

fullcone_image_part_info() {
    local part="$1"

    awk -v wanted="$part" '$1 == wanted { print $1, $2, $3; found=1 } END { exit !found }' /tmp/partmap.image
}

fullcone_write_image_part() {
    local image="$1"
    local part="$2"
    local dest="$3"
    local info start size

    info="$(fullcone_image_part_info "$part")" || {
        v "RAID upgrade: partition $part is missing in image"
        return 1
    }
    set -- $info
    start="$2"
    size="$3"

    v "RAID upgrade: writing image partition $part to $dest..."
    get_image_dd "$image" of="$dest" ibs=512 obs=1M skip="$start" count="$size" conv=fsync
}

fullcone_mount_boot_part() {
    local bootpart="$1"
    local mountpoint="$2"
    local parttype=ext4

    mkdir -p "$mountpoint"
    part_magic_fat "$bootpart" && parttype=vfat
    mount -t "$parttype" -o rw,noatime "$bootpart" "$mountpoint"
}

fullcone_backup_existing_efi() {
    local bootparts="$1"
    local bootpart mnt=/tmp/fullcone-boot-backup

    rm -f /tmp/fullcone-bootx64.efi
    for bootpart in $bootparts; do
        fullcone_mount_boot_part "$bootpart" "$mnt" || continue
        if [ -s "$mnt/efi/boot/bootx64.efi" ]; then
            cp -af "$mnt/efi/boot/bootx64.efi" /tmp/fullcone-bootx64.efi
            umount "$mnt"
            return 0
        fi
        umount "$mnt"
    done
    return 0
}

fullcone_copy_path_from_newroot() {
    local newroot="$1"
    local src="$2"
    local initroot="$3"
    local destdir

    [ -e "$newroot$src" ] || return 0
    destdir="$initroot$(dirname "$src")"
    mkdir -p "$destdir"
    cp -L "$newroot$src" "$destdir/" 2>/dev/null || true
}

fullcone_copy_binary_with_libs() {
    local newroot="$1"
    local src="$2"
    local dest="$3"
    local initroot="$4"
    local loader lib

    if [ ! -x "$src" ] && [ -x "$newroot$src" ]; then
        src="$newroot$src"
    fi
    [ -x "$src" ] || return 1

    mkdir -p "$initroot$(dirname "$dest")"
    cp -L "$src" "$initroot$dest"

    loader="$(find "$newroot/lib" -maxdepth 1 -name 'ld-musl-*.so*' -type f 2>/dev/null | head -n 1)"
    if [ -n "$loader" ] && [ -x "$loader" ]; then
        "$loader" --list "$src" 2>/dev/null | sed -n 's/.*=> \(\/[^ ]*\).*/\1/p; s/^[[:space:]]*\(\/[^ ]*\).*/\1/p' | while read -r lib; do
            [ -n "$lib" ] && fullcone_copy_path_from_newroot "$newroot" "$lib" "$initroot"
        done
    fi

    for lib in \
        /lib/ld-musl-*.so* \
        /lib/libc.so* \
        /lib/libgcc_s.so* \
        /usr/lib/libblkid.so* \
        /usr/lib/libuuid.so* \
        /usr/lib/libudev*.so*
    do
        for item in "$newroot"$lib; do
            [ -e "$item" ] || continue
            fullcone_copy_path_from_newroot "$newroot" "${item#$newroot}" "$initroot"
        done
    done
}

fullcone_copy_raid_modules() {
    local newroot="$1"
    local initroot="$2"
    local module destdir

    for module in libcrc32c.ko crc32c_generic.ko md-mod.ko raid1.ko; do
        find "$newroot/lib/modules" -name "$module" -type f 2>/dev/null | while read -r src; do
            destdir="$initroot$(dirname "${src#$newroot}")"
            mkdir -p "$destdir"
            cp -af "$src" "$destdir/"
        done
    done
}

fullcone_build_raid_initramfs() {
    local newroot="$1"
    local output="$2"
    local initroot=/tmp/fullcone-raid-initramfs
    local busybox mdadm_bin app

    rm -rf "$initroot"
    mkdir -p "$initroot/bin" "$initroot/sbin" "$initroot/proc" "$initroot/sys" "$initroot/dev" "$initroot/newroot" "$initroot/lib"

    busybox="$newroot/bin/busybox"
    [ -x "$busybox" ] || busybox=/bin/busybox
    fullcone_copy_binary_with_libs "$newroot" "$busybox" /bin/busybox "$initroot" || {
        v "RAID upgrade: unable to copy busybox into initramfs"
        return 1
    }

    for app in ash cat echo find grep head insmod ln ls mkdir mknod mount printf readlink reboot rm sed sh sleep sort stty switch_root sync tail test touch tr true umount uname; do
        ln -sf /bin/busybox "$initroot/bin/$app"
    done
for app in mdev; do
    ln -sf /bin/busybox "$initroot/sbin/$app"
done

    for mdadm_bin in "$newroot/sbin/mdadm" "$newroot/usr/sbin/mdadm" /sbin/mdadm /usr/sbin/mdadm; do
        if [ -x "$mdadm_bin" ]; then
            fullcone_copy_binary_with_libs "$newroot" "$mdadm_bin" /sbin/mdadm "$initroot" || true
            break
        fi
    done
    [ -x "$initroot/sbin/mdadm" ] || {
        v "RAID upgrade: mdadm is missing"
        return 1
    }

    fullcone_copy_raid_modules "$newroot" "$initroot"

    cat > "$initroot/init" <<'RAIDINIT'
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null || {
    mkdir -p /dev
    mknod /dev/console c 5 1 2>/dev/null
    mknod /dev/null c 1 3 2>/dev/null
    mdev -s 2>/dev/null
}
mkdir -p /dev/md /newroot

for mod in libcrc32c crc32c_generic md-mod raid1; do
    find /lib/modules -name "$mod.ko" -type f -exec insmod {} \; 2>/dev/null
done

mdev -s 2>/dev/null
mdadm --assemble /dev/md/openwrt-root --scan --run 2>/tmp/mdadm.log || \
mdadm --assemble /dev/md/openwrt-root /dev/sd*2 /dev/vd*2 /dev/xvd*2 /dev/nvme*n*p2 /dev/mmcblk*p2 --run 2>>/tmp/mdadm.log

for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -b /dev/md/openwrt-root ] && break
    sleep 1
done

mount -o ro /dev/md/openwrt-root /newroot 2>/tmp/rootmount.log || {
    echo "Unable to mount /dev/md/openwrt-root"
    cat /tmp/mdadm.log 2>/dev/null
    cat /tmp/rootmount.log 2>/dev/null
    exec sh
}

exec switch_root /newroot /sbin/init
RAIDINIT
    chmod +x "$initroot/init"

    (cd "$initroot" && find . -print0 | cpio --null -o --format=newc | gzip -9) > "$output"
    [ -s "$output" ]
}

fullcone_write_mdadm_config() {
    local newroot="$1"
    local mddev="$2"
    local uuid

    uuid="$(mdadm --detail --scan "$mddev" 2>/dev/null | sed -n 's/.*UUID=\([^ ]*\).*/\1/p' | head -n 1)"
    [ -n "$uuid" ] || uuid="$(mdadm --detail "$mddev" 2>/dev/null | sed -n 's/^[[:space:]]*UUID : //p' | head -n 1)"

    mkdir -p "$newroot/etc/config"
    cat > "$newroot/etc/config/mdadm" <<EOF
config mdadm
    list devices /dev/sd*
    list devices /dev/vd*
    list devices /dev/xvd*
    list devices /dev/nvme*
    list devices /dev/mmcblk*
    list devices partitions

config array
    option uuid ${uuid}
    option device /dev/md/openwrt-root
EOF
}

fullcone_upgrade_bios_bootloader() {
    local disk="$1"
    local bootmnt="$2"
    local parttable=msdos

    command -v grub-bios-setup >/dev/null 2>&1 || return 0
    [ -d "$bootmnt/boot/grub" ] || return 0

    part_magic_efi "$disk" && parttable=gpt
    echo "(hd0) $disk" > /tmp/fullcone-device.map
    grub-bios-setup \
        -m /tmp/fullcone-device.map \
        -d "$bootmnt/boot/grub" \
        -r "hd0,${parttable}1" \
        "$disk" || v "RAID upgrade: BIOS GRUB refresh failed on $disk, continuing"
}

fullcone_write_raid_boot_files() {
    local bootpart="$1"
    local disk
    local mnt=/tmp/fullcone-boot

    rm -rf "$mnt"
    mkdir -p "$mnt"
    fullcone_mount_boot_part "$bootpart" "$mnt" || {
        v "RAID upgrade: unable to mount $bootpart"
        return 1
    }

    mkdir -p "$mnt/boot/grub" "$mnt/efi/boot"
    cp -af /tmp/fullcone-raid-initramfs.gz "$mnt/boot/raid-initramfs.gz"
    if [ -s /tmp/fullcone-bootx64.efi ]; then
        cp -af /tmp/fullcone-bootx64.efi "$mnt/efi/boot/bootx64.efi"
    fi

    cat > "$mnt/boot/grub/grub.cfg" <<'GRUB'
set default=0
set timeout=3
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_input console serial
terminal_output console serial

menuentry "ImmortalWrt RAID1" {
    linux /boot/vmlinuz root=/dev/md/openwrt-root rootwait console=ttyS0,115200n8 console=tty1
    initrd /boot/raid-initramfs.gz
}

menuentry "ImmortalWrt RAID1 failsafe" {
    linux /boot/vmlinuz root=/dev/md/openwrt-root rootwait failsafe=true console=ttyS0,115200n8 console=tty1
    initrd /boot/raid-initramfs.gz
}
GRUB

    disk="$(fullcone_parent_disk_from_part "$bootpart" 2>/dev/null || true)"
    [ -n "$disk" ] && fullcone_upgrade_bios_bootloader "$disk" "$mnt"

    sync
    umount "$mnt"
}

platform_check_image() {
    if ! fullcone_is_mdraid_root; then
        platform_check_image_stock "$@"
        return $?
    fi

    [ "$#" -gt 1 ] && return 1
    case "$(get_magic_word "$1")" in
        eb48|eb63) ;;
        *)
            v "Invalid image type"
            return 1
        ;;
    esac

    fullcone_prepare_image_partmap "$1" || {
        v "RAID upgrade: image must be a normal x86 combined image with boot and root partitions"
        return 1
    }
    rm -f /tmp/partmap.image
    v "RAID upgrade: normal x86 image accepted for mdadm RAID1 root"
    return 0
}

platform_do_upgrade() {
    local image="$1"
    local mddev bootparts bootpart newroot=/tmp/fullcone-newroot

    if ! fullcone_is_mdraid_root; then
        platform_do_upgrade_stock "$@"
        return $?
    fi

    mddev="$(fullcone_mdraid_root_dev)" || {
        v "RAID upgrade: unable to determine mdadm root device"
        return 1
    }

    [ -b "$mddev" ] || mdadm --assemble --scan --run 2>/dev/null || true
    [ -b "$mddev" ] || {
        v "RAID upgrade: root array $mddev is not available"
        return 1
    }

    fullcone_prepare_image_partmap "$image" || return 1
    bootparts="$(fullcone_mdraid_boot_parts "$mddev")"
    [ -n "$bootparts" ] || {
        v "RAID upgrade: no RAID member boot partitions found"
        return 1
    }

    fullcone_backup_existing_efi "$bootparts"

    for bootpart in $bootparts; do
        fullcone_write_image_part "$image" 1 "$bootpart" || return 1
    done

    fullcone_write_image_part "$image" 2 "$mddev" || return 1
    e2fsck -fy "$mddev" || true
    resize2fs "$mddev" || true

    rm -rf "$newroot"
    mkdir -p "$newroot"
    mount -o rw,noatime "$mddev" "$newroot" || {
        v "RAID upgrade: unable to mount upgraded root array"
        return 1
    }

    fullcone_write_mdadm_config "$newroot" "$mddev"
    fullcone_build_raid_initramfs "$newroot" /tmp/fullcone-raid-initramfs.gz || {
        umount "$newroot"
        return 1
    }
    sync
    umount "$newroot"

    for bootpart in $bootparts; do
        fullcone_write_raid_boot_files "$bootpart" || return 1
    done

    rm -f /tmp/partmap.image
    sync
    v "RAID upgrade: completed; reboot will use mdadm RAID1 root"
}

platform_copy_config() {
    local mddev bootpart mnt=/tmp/fullcone-boot-config parttype

    if ! fullcone_is_mdraid_root; then
        platform_copy_config_stock "$@"
        return $?
    fi

    [ -n "$UPGRADE_BACKUP" ] || return 0
    mddev="$(fullcone_mdraid_root_dev)" || return 1

    for bootpart in $(fullcone_mdraid_boot_parts "$mddev"); do
        rm -rf "$mnt"
        mkdir -p "$mnt"
        parttype=ext4
        part_magic_fat "$bootpart" && parttype=vfat
        mount -t "$parttype" -o rw,noatime "$bootpart" "$mnt" || continue
        cp -af "$UPGRADE_BACKUP" "$mnt/$BACKUP_FILE"
        sync
        umount "$mnt"
    done
}
'''

path.write_text(text.rstrip() + addon + "\n", encoding="utf-8")
PY

# FullConeFlow package (private; cloned with the injected FC_TOKEN)
if [ -z "${FC_TOKEN:-}" ]; then
  echo "ERROR: FC_TOKEN is required to stage private FullConeFlow package" >&2
  exit 1
fi
rm -rf /tmp/fcsrc
git clone --depth=1 "https://x-access-token:${FC_TOKEN}@github.com/fullcone/fullcone-flow.git" /tmp/fcsrc
test -f /tmp/fcsrc/package/fullcone-flow/Makefile || {
  echo "ERROR: /tmp/fcsrc/package/fullcone-flow/Makefile not found" >&2
  exit 1
}
mkdir -p package
rm -rf package/fullcone-flow package/luci-app-fullcone-flow
cp -a /tmp/fcsrc/package/fullcone-flow package/fullcone-flow
test -f package/fullcone-flow/Makefile || {
  echo "ERROR: package/fullcone-flow/Makefile was not staged" >&2
  exit 1
}
rm -rf /tmp/fcsrc
echo "FullConeFlow staged into package/"
