# fullcone checked x86 sysupgrade 20261018
FULLCONE_GPT_UPGRADE_REQUIRED=1
RAMFS_COPY_BIN="$RAMFS_COPY_BIN fullcone-target-gpt sgdisk mktemp readlink ln dirname head /usr/libexec/fullcone/busybox"

fullcone_upgrade_require_tools() {
    local tool
    for tool in fullcone-target-gpt sgdisk; do
        command -v "$tool" >/dev/null 2>&1 || { v "Upgrade refused: required tool $tool is missing"; return 1; }
        "$tool" --version >/dev/null 2>&1 || { v "Upgrade refused: $tool cannot execute with its runtime libraries"; return 1; }
    done
}

fullcone_upgrade_require_raid_tools() {
    local tool status=0
    for tool in mdadm e2fsck resize2fs grub-bios-setup readlink ln dirname head cpio gzip; do
        command -v "$tool" >/dev/null 2>&1 || { v "RAID upgrade refused: $tool is missing"; return 1; }
    done
    mdadm --version >/dev/null 2>&1 || return 1
    e2fsck -V >/dev/null 2>&1 || return 1
    grub-bios-setup --version >/dev/null 2>&1 || return 1
    resize2fs >/dev/null 2>&1 || status=$?
    case "$status" in 0|1) ;; *) v "resize2fs cannot execute with its runtime libraries"; return 1 ;; esac
    local bootbox=/usr/libexec/fullcone/busybox app applets
    [ -x "$bootbox" ] || { v "RAID upgrade refused: packaged initramfs BusyBox is missing"; return 1; }
    applets="$("$bootbox" --list)" || return 1
    for app in sh cat find grep insmod ln ls mkdir mknod mount readlink rm sed sleep stty switch_root sync tar umount uname mdev chroot; do
        printf '%s\n' "$applets" | grep -Fxq "$app" || { v "RAID upgrade refused: initramfs BusyBox lacks $app"; return 1; }
    done
    local probe
    probe="$(mktemp /tmp/fullcone-cpio.XXXXXX)" || return 1
    if ! cpio -0 -o -H newc </dev/null >"$probe" 2>/dev/null; then
        rm -f "$probe"
        v "RAID upgrade refused: cpio cannot create a newc archive"
        return 1
    fi
    [ "$(dd if="$probe" bs=6 count=1 2>/dev/null)" = 070701 ] || { rm -f "$probe"; return 1; }
    rm -f "$probe" || return 1
}

fullcone_upgrade_bind_md_root() {
    local device existing
    device="$(fullcone_mdraid_root_dev)" || return 1
    mkdir -p /dev/md || return 1
    if [ -e /dev/md/openwrt-root ] || [ -L /dev/md/openwrt-root ]; then
        existing="$(readlink -f /dev/md/openwrt-root)" || return 1
        [ "$existing" = "$device" ] || { v "Root md alias points to a different device"; return 1; }
    else
        ln -s "$device" /dev/md/openwrt-root || return 1
    fi
}

fullcone_prepare_checked_source() {
    local image="$1" disk="$2" dir
    fullcone_upgrade_require_tools || return 1
    dir="$(mktemp -d /tmp/fullcone-upgrade.XXXXXX)" || return 1
    FULLCONE_UPGRADE_PLAN="$dir/plan"
    v "Validating complete image stream before writing; recovery plan: $FULLCONE_UPGRADE_PLAN"
    if [ -n "$disk" ]; then
        (set -o pipefail; get_image "$image" | fullcone-target-gpt --upgrade-prepare "$disk" "$FULLCONE_UPGRADE_PLAN") || return 1
    else
        (set -o pipefail; get_image "$image" | fullcone-target-gpt --image-prepare "$FULLCONE_UPGRADE_PLAN") || return 1
    fi
}

fullcone_prepare_checked_preview() {
    local image="$1" disk="$2" dir
    fullcone_upgrade_require_tools || return 1
    dir="$(mktemp -d /tmp/fullcone-preview.XXXXXX)" || return 1
    FULLCONE_UPGRADE_PLAN="$dir/plan"
    # procd synchronously calls platform_check_image on its event loop.
    # This deliberately bounded metadata read may terminate zcat with SIGPIPE.
    # Preview plans cannot authorize writes; stage2 validates the full stream
    # with pipefail before touching any target partition or disk.
    if [ -n "$disk" ]; then
        (set +o pipefail; get_image "$image" 2>/dev/null | fullcone-target-gpt --preview-prepare "$disk" "$FULLCONE_UPGRADE_PLAN") || return 1
    else
        (set +o pipefail; get_image "$image" 2>/dev/null | fullcone-target-gpt --image-preview "$FULLCONE_UPGRADE_PLAN") || return 1
    fi
}

fullcone_checked_copy() {
    local image="$1" part="$2" dest="$3"
    [ -n "$FULLCONE_UPGRADE_PLAN" ] || { v "Missing verified upgrade plan"; return 1; }
    (set -o pipefail; get_image "$image" | fullcone-target-gpt --stream-write "$FULLCONE_UPGRADE_PLAN" "$part" "$dest")
}

fullcone_check_image_destination() {
    [ -n "$FULLCONE_UPGRADE_PLAN" ] || return 1
    fullcone-target-gpt --part-check "$FULLCONE_UPGRADE_PLAN" "$1" "$2"
}

fullcone_checked_fsck_resize() {
    local device="$1" status=0
    e2fsck -fy "$device" || status=$?
    case "$status" in
        0|1) ;;
        2|3) v "Filesystem check requires reboot; stopping upgrade without automatic reboot"; return 1 ;;
        *) v "Filesystem check failed with status $status"; return 1 ;;
    esac
    resize2fs "$device" || return 1
}
