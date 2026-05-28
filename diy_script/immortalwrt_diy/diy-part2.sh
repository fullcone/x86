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

# GOLANG_TIME=$(cd temp_resp/openwrt_packages && git log -1 --format=%cd --date=unix -- lang/golang)
# RUST_TIME=$(cd temp_resp/openwrt_packages && git log -1 --format=%cd --date=unix -- lang/rust)

# # 建立专门的 override 目录，不碰 feeds
# rm -rf package/custom_overrides
# mkdir -p package/custom_overrides

# cp -a temp_resp/openwrt_packages/lang/golang package/custom_overrides/
# cp -a temp_resp/openwrt_packages/lang/rust package/custom_overrides/

# # 注入真实时间戳
# if [ -n "$GOLANG_TIME" ]; then
#     find package/custom_overrides/golang -exec touch -m -d @"$GOLANG_TIME" {} +
# else
#     echo "⚠️ 警告: 无法提取 Golang 的上游时间戳，将使用拷贝时的时间"
# fi

# if [ -n "$RUST_TIME" ]; then
#     find package/custom_overrides/rust -exec touch -m -d @"$RUST_TIME" {} +
# else
#     echo "⚠️ 警告: 无法提取 Rust 的上游时间戳，将使用拷贝时的时间"
# fi


# rm -rf temp_resp
#-------------------------------------------------------end 移植包--------------------------------------------------------


#-----------------------------------------------修改脚本------------------------------------------------------------

# rm appfilter
rm -rf ./feeds/packages/net/open-app-filter

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

# ./scripts/feeds update -a
# ./scripts/feeds install -a

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
    [ -z "$value" ] && value="$default"
eval "$var=\"\$value\""
}

yesno() {
    local label="$1"
    local default="$2"
    local value
    printf '%s [%s]: ' "$label" "$default"
    read -r value
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

ensure_bridge_device() {
    local bridge="$1"
    local port="$2"
    local section
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
    echo 'Interface input accepts a physical NIC like eth2 or a VLAN like eth3.1226.'
    echo

    prompt lan_dev 'LAN interface' "$(bridge_first_port br-lan eth0)"
    prompt lan_ip 'LAN IPv4 address' "$(current_or_default network.lan.ipaddr 172.16.101.254)"
    prompt lan_mask 'LAN netmask' "$(current_or_default network.lan.netmask 255.255.255.0)"

    if yesno 'Configure WAN1 static IPv4' 'y'; then
        prompt wan1_dev 'WAN1 interface' "$(current_or_default network.wan1.device eth2)"
        prompt wan1_ip 'WAN1 IPv4 address' "$(current_or_default network.wan1.ipaddr 172.16.0.52)"
        prompt wan1_mask 'WAN1 netmask' "$(current_or_default network.wan1.netmask 255.255.255.0)"
        prompt wan1_gw 'WAN1 gateway' "$(current_or_default network.wan1.gateway 172.16.0.254)"
        prompt wan1_dns 'WAN1 DNS servers' "$(current_or_default network.wan1.dns '223.5.5.5 119.29.29.29')"
        prompt wan1_metric 'WAN1 route metric' "$(current_or_default network.wan1.metric 10)"
    fi

    echo
    echo 'WAN2 mode:'
    echo '  0) skip WAN2'
    echo '  1) static IPv4 on physical interface'
    echo '  2) PPPoE on physical interface'
    echo '  3) PPPoE on one VLAN, for example eth3.1226'
    echo '  4) PPPoE on two VLANs, for example eth3.1226 and eth3.1227'
    prompt wan2_mode 'WAN2 mode' '4'
    case "$wan2_mode" in
        1)
            prompt wan2_dev 'WAN2 interface' "$(current_or_default network.wan2.device eth3)"
            prompt wan2_ip 'WAN2 IPv4 address' "$(current_or_default network.wan2.ipaddr '')"
            prompt wan2_mask 'WAN2 netmask' "$(current_or_default network.wan2.netmask 255.255.255.0)"
            prompt wan2_gw 'WAN2 gateway' "$(current_or_default network.wan2.gateway '')"
            prompt wan2_dns 'WAN2 DNS servers' "$(current_or_default network.wan2.dns '223.5.5.5 119.29.29.29')"
            prompt wan2_metric 'WAN2 route metric' "$(current_or_default network.wan2.metric 20)"
            ;;
        2)
            prompt ppp_dev 'WAN2 physical interface' "$(current_or_default network.wan2.device eth3)"
            prompt user1 'WAN2 PPPoE username' "$(current_or_default network.wan2.username '')"
            printf 'WAN2 PPPoE password [leave blank to keep existing]: '
            read -r pass1
            prompt metric1 'WAN2 PPPoE route metric' "$(current_or_default network.wan2.metric 20)"
            ;;
        3)
            prompt ppp_dev 'WAN2 physical interface' eth3
            prompt vlan1 'WAN2 VLAN ID' "$(current_or_default network.wan2_1226.device eth3.1226 | sed 's/.*\.//')"
            wan2_section="wan2_${vlan1}"
            prompt user1 'WAN2 PPPoE username' "$(current_or_default network."$wan2_section".username '')"
            printf 'WAN2 PPPoE password [leave blank to keep existing]: '
            read -r pass1
            prompt metric1 'WAN2 PPPoE route metric' "$(current_or_default network."$wan2_section".metric 20)"
            ;;
        4)
            prompt ppp_dev 'WAN2 physical interface' eth3
            prompt vlan1 'First VLAN ID' "$(current_or_default network.wan2_1226.device eth3.1226 | sed 's/.*\.//')"
            wan2_section1="wan2_${vlan1}"
            prompt user1 'First PPPoE username' "$(current_or_default network."$wan2_section1".username "$(current_or_default network.wan2_1226.username '')")"
            printf 'First PPPoE password [leave blank to keep existing]: '
            read -r pass1
            prompt metric1 'First PPPoE route metric' "$(current_or_default network."$wan2_section1".metric "$(current_or_default network.wan2_1226.metric 20)")"
            prompt vlan2 'Second VLAN ID' "$(current_or_default network.wan2_1227.device eth3.1227 | sed 's/.*\.//')"
            wan2_section2="wan2_${vlan2}"
            prompt user2 'Second PPPoE username' "$(current_or_default network."$wan2_section2".username "$(current_or_default network.wan2_1227.username '')")"
            printf 'Second PPPoE password [leave blank to keep existing]: '
            read -r pass2
            prompt metric2 'Second PPPoE route metric' "$(current_or_default network."$wan2_section2".metric "$(current_or_default network.wan2_1227.metric 30)")"
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
