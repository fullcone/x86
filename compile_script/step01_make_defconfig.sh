#!/bin/bash
source $GITHUB_WORKSPACE/compile_script/platforms.sh
source_code_platform=$1
CONFIGS=$2
Is_Copy_Seeds=$3

if [[ "$source_code_platform" == "openwrt" ]]; then
  selected_platforms=("${openwrt_platforms[@]}")
elif [[ "$source_code_platform" == "immortalwrt" ]]; then
  selected_platforms=("${immortalwrt_platforms[@]}")
elif [[ "$source_code_platform" == "lede" ]]; then
  selected_platforms=("${lede_platforms[@]}")
fi

cd ..
for i in "${selected_platforms[@]}"; do
    echo $i
    [ -e $CONFIGS/$i.config ] && cp -a $CONFIGS/$i.config openwrt/.config
    cd openwrt
    if [[ "$Is_Copy_Seeds" == "true" ]]; then
      echo ""
      echo "copy seed for $i platform....."
      cat $GITHUB_WORKSPACE/config/seed/${source_code_platform}_seed.config >> .config
      echo ""
    fi
    echo ""
    echo "make defconfig for $i platform....."
    echo "result:"
    # fullcone verify generated package configuration
    defconfig_log="$GITHUB_WORKSPACE/defconfig-$i.log"
    if ! make defconfig > "$defconfig_log" 2>&1; then
        cat "$defconfig_log"
        exit 1
    fi
    cat "$defconfig_log"
    if grep -q 'error: recursive dependency detected' "$defconfig_log"; then
        echo "Invalid package Kconfig for $i"
        exit 1
    fi
    case "$i" in
        X86|X86_AllImages|X86_VMware)
            for package in nikki luci-app-nikki luci-i18n-nikki-zh-cn mihomo-meta tc-full fullcone-flow luci-app-accesspolicycontroller; do
                grep -Fxq "CONFIG_PACKAGE_$package=y" .config || {
                    echo "Required Nikki package dropped by defconfig: $package ($i)"
                    exit 1
                }
            done
            if grep -qE '^CONFIG_PACKAGE_(mihomo-alpha|tc-bpf|tc-tiny)=[ym]$' .config; then
                echo "Unexpected alternative provider selected for $i"
                exit 1
            fi
            ;;
    esac
    echo ""
    cd ..
    cp -a openwrt/.config $CONFIGS/$i.config
done
cd openwrt
rm -rf .config
