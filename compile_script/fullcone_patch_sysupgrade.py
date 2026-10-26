from pathlib import Path
import os,re,shutil

MARK='# fullcone checked x86 sysupgrade 20261018'
def replace(s,old,new):
    if s.count(old)!=1:raise SystemExit('Expected one x86 upgrade anchor: '+old[:100])
    return s.replace(old,new,1)
def function(s,name,callback):
    pattern=r'^'+re.escape(name)+r'\(\) \{\n.*?(?=^[A-Za-z_][A-Za-z_0-9]*\(\) \{|\Z)'
    found=list(re.finditer(pattern,s,re.M|re.S))
    if len(found)!=1:raise SystemExit('Expected one function: '+name)
    m=found[0];return s[:m.start()]+callback(m.group())+s[m.end():]

repo=Path(os.environ['GITHUB_WORKSPACE'])
package=Path('package/custom_packages/fullcone-target-gpt');(package/'src').mkdir(parents=True,exist_ok=True)
shutil.copyfile(repo/'compile_script/fullcone_gpt_package.Makefile',package/'Makefile')
(package/'Config.in').write_text('''config FULLCONE_RAID_INITRAMFS_TOOLS
	bool
	default y if PACKAGE_fullcone-target-gpt
	select BUSYBOX_DEFAULT_BUSYBOX
	select BUSYBOX_DEFAULT_STTY
	select BUSYBOX_DEFAULT_CPIO
	select BUSYBOX_DEFAULT_FEATURE_CPIO_O
	select BUSYBOX_DEFAULT_INSMOD if !BUSYBOX_DEFAULT_MODPROBE_SMALL
	select BUSYBOX_DEFAULT_MDEV
	select BUSYBOX_CONFIG_BUSYBOX if BUSYBOX_CUSTOM
	select BUSYBOX_CONFIG_STTY if BUSYBOX_CUSTOM
	select BUSYBOX_CONFIG_CPIO if BUSYBOX_CUSTOM
	select BUSYBOX_CONFIG_FEATURE_CPIO_O if BUSYBOX_CUSTOM
	select BUSYBOX_CONFIG_INSMOD if BUSYBOX_CUSTOM && !BUSYBOX_CONFIG_MODPROBE_SMALL
	select BUSYBOX_CONFIG_MDEV if BUSYBOX_CUSTOM
''')
for name in ['fullcone_target_gpt.c','fullcone_upgrade_gpt.c']:shutil.copyfile(repo/'compile_script'/name,package/'src'/name)
path=Path('target/linux/x86/base-files/lib/upgrade/platform.sh');s=path.read_text()
if MARK not in s:
    def check(t):
        t=replace(t,'\tget_partitions "/dev/$diskdev" bootdisk','\tfullcone-target-gpt --partmap "$FULLCONE_UPGRADE_PLAN" old > /tmp/partmap.bootdisk || return 1')
        t=replace(t,'\tget_image_dd "$1" of=/tmp/image.bs count=63 bs=512b','\t# Source metadata was validated before this stock layout check.')
        t=replace(t,'\tget_partitions /tmp/image.bs image','\tfullcone-target-gpt --partmap "$FULLCONE_UPGRADE_PLAN" source > /tmp/partmap.image || return 1')
        t=replace(t,'\trm -f /tmp/image.bs /tmp/partmap.bootdisk /tmp/partmap.image','''	local format_status=0
	fullcone-target-gpt --same-format "$FULLCONE_UPGRADE_PLAN" || format_status=$?
	case "$format_status" in 0) ;; 2) diff=1 ;; *) return 1 ;; esac
	rm -f /tmp/partmap.bootdisk /tmp/partmap.image''')
        return t
    s=function(s,'platform_check_image_stock',check)
    def stock(t):
        t=replace(t,'\tsync\n','\tsync || return 1\n\tfullcone_prepare_checked_source "$1" "/dev/$diskdev" || return 1\n')
        t=replace(t,'\t\tget_partitions "/dev/$diskdev" bootdisk','\t\tfullcone-target-gpt --partmap "$FULLCONE_UPGRADE_PLAN" old > /tmp/partmap.bootdisk || return 1')
        t=replace(t,'\t\tget_image_dd "$1" of=/tmp/image.bs count=63 bs=512b','\t\t# Use the complete-source-validated metadata, not an unchecked bounded pipe.')
        t=replace(t,'\t\tget_partitions /tmp/image.bs image','\t\tfullcone-target-gpt --partmap "$FULLCONE_UPGRADE_PLAN" source > /tmp/partmap.image || return 1')
        t=replace(t,'\tif [ -n "$diff" ]; then','''	local format_status=0
	fullcone-target-gpt --same-format "$FULLCONE_UPGRADE_PLAN" || format_status=$?
	case "$format_status" in 0) ;; 2) diff=1 ;; *) return 1 ;; esac
	if [ -n "$diff" ]; then''')
        t=replace(t,'\t\tget_image_dd "$1" of="/dev/$diskdev" bs=4096 conv=fsync','\t\tfullcone_checked_copy "$1" 0 "/dev/$diskdev" || return 1\n\t\tfullcone-target-gpt --upgrade-finish "/dev/$diskdev" "$FULLCONE_UPGRADE_PLAN" || return 1')
        t=replace(t,'\t\tpartx -d - "/dev/$diskdev"','\t\tpartx -d - "/dev/$diskdev" || return 1')
        t=replace(t,'\t\tpartx -a - "/dev/$diskdev"','\t\tpartx -a - "/dev/$diskdev" || return 1')
        t=replace(t,'\t#iterate over each partition from the image and write it to the boot disk','''	# Check every destination before writing any partition; retain extra partitions.
	while read part start size; do
		export_partdevice partdev "$part" || return 1
		fullcone_check_image_destination "$part" "/dev/$partdev" || return 1
	done < /tmp/partmap.image
	command -v grub-bios-setup >/dev/null 2>&1 || return 1
	grub-bios-setup --version >/dev/null 2>&1 || return 1
	#iterate over each partition from the image and write it to the boot disk''')
        t=replace(t,'\t\t\tget_image_dd "$1" of="/dev/$partdev" ibs=512 obs=1M skip="$start" count="$size" conv=fsync','\t\t\tfullcone_checked_copy "$1" "$part" "/dev/$partdev" || return 1')
        t=replace(t,'\t\t\tv "Unable to find partition $part device, skipped."','\t\t\tv "Unable to find partition $part device."\n\t\t\treturn 1')
        t=replace(t,'\tget_image_dd "$1" of="/dev/$diskdev" bs=1 skip=440 count=4 seek=440 conv=fsync','\tfullcone-target-gpt --signature-write "$FULLCONE_UPGRADE_PLAN" "/dev/$diskdev" || return 1')
        t=replace(t,'\tplatform_do_bootloader_upgrade "$diskdev"','\tplatform_do_bootloader_upgrade "$diskdev" || return 1')
        t=replace(t,'\tpart_magic_efi "/dev/$diskdev" || return 0','\tpart_magic_efi "/dev/$diskdev" || { fullcone-target-gpt --partition-finish "$FULLCONE_UPGRADE_PLAN" "/dev/$diskdev"; return $?; }')
        t=replace(t,'\t\tmount -t $parttype -o rw,noatime "/dev/$partdev" /mnt','\t\tmount -t $parttype -o rw,noatime "/dev/$partdev" /mnt || return 1')
        t=replace(t,'\t\tsed -i "s/\\(PARTUUID=\\)[a-f0-9-]\\+/\\1$4$3$2$1-$6$5-$8$7-$9/ig" /mnt/boot/grub/grub.cfg','''		[ "$#" -eq 9 ] || { umount /mnt; return 1; }
		sed -i "s/\\(PARTUUID=\\)[a-f0-9-]\\+/\\1$4$3$2$1-$6$5-$8$7-$9/ig" /mnt/boot/grub/grub.cfg || { umount /mnt; return 1; }''')
        t=replace(t,'\t\tumount /mnt\n\tfi\n}', '\t\tumount /mnt || return 1\n\telse\n\t\treturn 1\n\tfi\n\tfullcone-target-gpt --partition-finish "$FULLCONE_UPGRADE_PLAN" "/dev/$diskdev"\n}')
        return t
    s=function(s,'platform_do_upgrade_stock',stock)
    def bootloader(t):
        t=replace(t,'\t\tmkdir -p /tmp/boot','\t\tmkdir -p /tmp/boot || return 1')
        t=replace(t,'\t\tmount -o rw,noatime "/dev/$bootpart" /tmp/boot','\t\tmount -o rw,noatime "/dev/$bootpart" /tmp/boot || return 1')
        t=replace(t,'\t\techo "(hd0) /dev/$diskdev" > /tmp/device.map','\t\techo "(hd0) /dev/$diskdev" > /tmp/device.map || { umount /tmp/boot; return 1; }')
        t=replace(t,'\t\t\t"/dev/$diskdev"','\t\t\t"/dev/$diskdev" || { umount /tmp/boot; return 1; }')
        t=replace(t,'\t\tumount /tmp/boot\n\tfi','\t\tumount /tmp/boot || return 1\n\telse\n\t\treturn 1\n\tfi')
        return t
    s=function(s,'platform_do_bootloader_upgrade',bootloader)
    def config_stock(t):
        t=replace(t,'\t\tmount -t $parttype -o rw,noatime "/dev/$partdev" /mnt','\t\tmount -t $parttype -o rw,noatime "/dev/$partdev" /mnt || return 1')
        t=replace(t,'\t\tcp -af "$UPGRADE_BACKUP" "/mnt/$BACKUP_FILE"','\t\tcp -af "$UPGRADE_BACKUP" "/mnt/$BACKUP_FILE" || { umount /mnt; return 1; }')
        return replace(t,'\t\tumount /mnt\n\tfi','\t\tumount /mnt || return 1\n\telse\n\t\treturn 1\n\tfi')
    s=function(s,'platform_copy_config_stock',config_stock)
    s=function(s,'fullcone_mdraid_root_dev',lambda t:'''fullcone_mdraid_root_dev() {
    local identity real name
    # mdev can drop the early-initramfs alias after switch_root. Locate the
    # mounted root by kernel device number, never by an arbitrary md array.
    for identity in $(awk '$5 == "/" || $5 == "/rom" { print $3 }' /proc/self/mountinfo); do
        [ -d "/sys/dev/block/$identity/md" ] || continue
        real="$(readlink -f "/sys/dev/block/$identity")" || return 1
        name="${real##*/}"
        [ -b "/dev/$name" ] && { echo "/dev/$name"; return 0; }
    done
    # stage2 has pivoted away from the old root; stage1 bound this root alias
    # in /dev, whose mount is moved intact into the upgrade RAMFS.
    if grep -qw 'root=/dev/md/openwrt-root' /proc/cmdline && [ -b /dev/md/openwrt-root ]; then
        real="$(readlink -f /dev/md/openwrt-root)" || return 1
        name="${real##*/}"
        [ -d "/sys/class/block/$name/md" ] && { echo "$real"; return 0; }
    fi
    return 1
}

''')
    def check_wrapper(t):
        return replace(t,'platform_check_image() {','''platform_check_image() {
    local fullcone_check_disk
    if fullcone_is_mdraid_root; then
        fullcone_upgrade_require_raid_tools || return 1
        fullcone_upgrade_bind_md_root || return 1
        fullcone_prepare_checked_preview "$1" || return 1
    else
        export_bootdevice && export_partdevice fullcone_check_disk 0 || return 1
        fullcone_prepare_checked_preview "$1" "/dev/$fullcone_check_disk" || return 1
    fi''')
    s=function(s,'platform_check_image',check_wrapper)
    s=function(s,'fullcone_prepare_image_partmap',lambda t:'''fullcone_prepare_image_partmap() {
    [ -n "$FULLCONE_UPGRADE_PLAN" ] || return 1
    fullcone-target-gpt --partmap "$FULLCONE_UPGRADE_PLAN" source > /tmp/partmap.image || return 1
    grep -q '^ *1[[:space:]]' /tmp/partmap.image && grep -q '^ *2[[:space:]]' /tmp/partmap.image
}

''')
    def raid(t):
        t=replace(t,'    fullcone_prepare_image_partmap "$image" || return 1','    fullcone_prepare_checked_source "$image" || return 1\n    fullcone_prepare_image_partmap "$image" || return 1')
        t=replace(t,'    fullcone_backup_existing_efi "$bootparts"','''    for bootpart in $bootparts; do
        fullcone_check_image_destination 1 "$bootpart" || return 1
    done
    fullcone_check_image_destination 2 "$mddev" || return 1
    fullcone_upgrade_require_raid_tools || return 1
    fullcone_backup_existing_efi "$bootparts" || return 1''')
        t=replace(t,'    e2fsck -fy "$mddev" || true\n    resize2fs "$mddev" || true','    fullcone_checked_fsck_resize "$mddev" || return 1')
        t=replace(t,'    fullcone_write_mdadm_config "$newroot" "$mddev"','    fullcone_write_mdadm_config "$newroot" "$mddev" || { umount "$newroot"; return 1; }')
        t=replace(t,'    sync\n    umount "$newroot"','''    if [ -n "$UPGRADE_BACKUP" ]; then
        cp -af "$UPGRADE_BACKUP" "$newroot/.fullcone-sysupgrade.tgz" || { umount "$newroot"; return 1; }
        fullcone-target-gpt --file-equal "$UPGRADE_BACKUP" "$newroot/.fullcone-sysupgrade.tgz" || { umount "$newroot"; return 1; }
    fi
    sync || { umount "$newroot"; return 1; }
    umount "$newroot" || return 1''')
        return t
    s=function(s,'platform_do_upgrade',raid)
    s=function(s,'fullcone_write_image_part',lambda t:replace(t,'    get_image_dd "$image" of="$dest" ibs=512 obs=1M skip="$start" count="$size" conv=fsync','    fullcone_checked_copy "$image" "$part" "$dest"'))
    def raid_bios(t):
        t=replace(t,'    command -v grub-bios-setup >/dev/null 2>&1 || return 0','    command -v grub-bios-setup >/dev/null 2>&1 || return 1')
        t=replace(t,'    [ -d "$bootmnt/boot/grub" ] || return 0','    [ -d "$bootmnt/boot/grub" ] || return 1')
        t=replace(t,'    echo "(hd0) $disk" > /tmp/fullcone-device.map','    echo "(hd0) $disk" > /tmp/fullcone-device.map || return 1')
        return replace(t,'        "$disk" || v "RAID upgrade: BIOS GRUB refresh failed on $disk, continuing"','        "$disk" || { v "RAID upgrade: BIOS GRUB refresh failed on $disk"; return 1; }')
    s=function(s,'fullcone_upgrade_bios_bootloader',raid_bios)
    def raid_boot(t):
        # Match the official GPT boot configuration: BIOS core.img can leave
        # root on the MD member instead of the separate kernel filesystem.
        t=replace(t,'set timeout=3\nserial --unit=0','set timeout=3\nsearch -l kernel -s root\nserial --unit=0')
        for old in ['    mkdir -p "$mnt"','    mkdir -p "$mnt/boot/grub" "$mnt/efi/boot"','    cp -af /tmp/fullcone-raid-initramfs.gz "$mnt/boot/raid-initramfs.gz"','        cp -af /tmp/fullcone-bootx64.efi "$mnt/efi/boot/bootx64.efi"']:
            t=replace(t,old,old+' || { umount "$mnt"; return 1; }')
        t=replace(t,'    cat > "$mnt/boot/grub/grub.cfg" <<\'GRUB\'','    cat > "$mnt/boot/grub/grub.cfg" <<\'GRUB\' || { umount "$mnt"; return 1; }')
        t=replace(t,'    [ -n "$disk" ] && fullcone_upgrade_bios_bootloader "$disk" "$mnt"','    [ -n "$disk" ] && fullcone_upgrade_bios_bootloader "$disk" "$mnt" || { umount "$mnt"; return 1; }')
        return replace(t,'    sync\n    umount "$mnt"','    sync || { umount "$mnt"; return 1; }\n    umount "$mnt" || return 1')
    s=function(s,'fullcone_write_raid_boot_files',raid_boot)
    s=function(s,'platform_copy_config',lambda t:'''platform_copy_config() {
    local mddev mnt=/tmp/fullcone-config-verify status=0
    if ! fullcone_is_mdraid_root; then
        platform_copy_config_stock "$@"
        return $?
    fi
    [ -n "$UPGRADE_BACKUP" ] || return 0
    mddev="$(fullcone_mdraid_root_dev)" || return 1
    mkdir -p "$mnt" || return 1
    mount -o ro "$mddev" "$mnt" || return 1
    fullcone-target-gpt --file-equal "$UPGRADE_BACKUP" "$mnt/.fullcone-sysupgrade.tgz" || status=1
    umount "$mnt" || return 1
    return "$status"
}

''')
    def checked_copies(t):
        t=replace(t,'    mkdir -p "$destdir"','    mkdir -p "$destdir" || return 1')
        return replace(t,'    cp -L "$newroot$src" "$destdir/" 2>/dev/null || true','    cp -L "$newroot$src" "$destdir/" || return 1')
    s=function(s,'fullcone_copy_path_from_newroot',checked_copies)
    def binary_copies(t):
        t=replace(t,'    mkdir -p "$initroot$(dirname "$dest")"','    mkdir -p "$initroot$(dirname "$dest")" || return 1')
        t=replace(t,'    cp -L "$src" "$initroot$dest"','    cp -L "$src" "$initroot$dest" || return 1')
        t=replace(t,'            [ -n "$lib" ] && fullcone_copy_path_from_newroot "$newroot" "$lib" "$initroot"','            [ -z "$lib" ] || fullcone_copy_path_from_newroot "$newroot" "$lib" "$initroot" || exit 1')
        t=replace(t,'        done\n    fi','        done || return 1\n    fi')
        t=replace(t,'            fullcone_copy_path_from_newroot "$newroot" "${item#$newroot}" "$initroot"','            fullcone_copy_path_from_newroot "$newroot" "${item#$newroot}" "$initroot" || return 1')
        return t
    s=function(s,'fullcone_copy_binary_with_libs',binary_copies)
    def modules(t):
        t=replace(t,'            mkdir -p "$destdir"','            mkdir -p "$destdir" || exit 1')
        t=replace(t,'            cp -af "$src" "$destdir/"','            cp -af "$src" "$destdir/" || exit 1')
        return replace(t,'        done\n    done','        done || return 1\n    done')
    s=function(s,'fullcone_copy_raid_modules',modules)
    s=function(s,'fullcone_mount_boot_part',lambda t:replace(t,'    mkdir -p "$mountpoint"','    mkdir -p "$mountpoint" || return 1'))
    def backup_efi(t):
        t=replace(t,'            cp -af "$mnt/efi/boot/bootx64.efi" /tmp/fullcone-bootx64.efi','            cp -af "$mnt/efi/boot/bootx64.efi" /tmp/fullcone-bootx64.efi || { umount "$mnt"; return 1; }')
        t=t.replace('umount "$mnt"\n','umount "$mnt" || return 1\n')
        return t
    s=function(s,'fullcone_backup_existing_efi',backup_efi)
    def md_config(t):
        t=replace(t,'    mkdir -p "$newroot/etc/config"','    [ -n "$uuid" ] || return 1\n    mkdir -p "$newroot/etc/config" || return 1')
        return replace(t,'    cat > "$newroot/etc/config/mdadm" <<EOF','    cat > "$newroot/etc/config/mdadm" <<EOF || return 1')
    s=function(s,'fullcone_write_mdadm_config',md_config)
    def raid_init(t):
        t=replace(t,'"$initroot/newroot" "$initroot/lib"','"$initroot/newroot" "$initroot/lib" "$initroot/tmp"')
        t=replace(t,'    local busybox mdadm_bin app','    local busybox mdadm_bin app uuid')
        t=replace(t,'    busybox="$newroot/bin/busybox"\n    [ -x "$busybox" ] || busybox=/bin/busybox','''    # Keep complete, preflighted userspace from the running firmware. Only
    # kernel modules come from the incoming image, matching its new kernel.
    busybox=/usr/libexec/fullcone/busybox''')
        t=replace(t,'    fullcone_copy_binary_with_libs "$newroot" "$busybox" /bin/busybox "$initroot"','    fullcone_copy_binary_with_libs / "$busybox" /bin/busybox "$initroot"')
        t=replace(t,'    for mdadm_bin in "$newroot/sbin/mdadm" "$newroot/usr/sbin/mdadm" /sbin/mdadm /usr/sbin/mdadm; do','    for mdadm_bin in /sbin/mdadm /usr/sbin/mdadm; do')
        t=replace(t,'            fullcone_copy_binary_with_libs "$newroot" "$mdadm_bin" /sbin/mdadm "$initroot" || true','            fullcone_copy_binary_with_libs / "$mdadm_bin" /sbin/mdadm "$initroot" || return 1')
        t=replace(t,'sort stty switch_root sync tail test touch tr true umount uname; do','sort stty switch_root sync tail tar test touch tr true umount uname; do')
        t=replace(t,'exec switch_root /newroot /sbin/init', '''# The backup is replicated in the md filesystem, so degraded boots restore it too.
if [ -f /newroot/.fullcone-sysupgrade.tgz ]; then
    if mount -o remount,rw /newroot && tar -xzf /newroot/.fullcone-sysupgrade.tgz -C /newroot; then
        rm /newroot/.fullcone-sysupgrade.tgz && sync && mount -o remount,ro /newroot || {
            echo "RAID configuration restore finalization failed; reboot inhibited"
            while :; do sh; sleep 1; done
        }
    else
        echo "RAID configuration restore failed; backup retained, reboot inhibited"
        while :; do sh; sleep 1; done
    fi
fi
exec switch_root /newroot /sbin/init''')
        t=replace(t,'    fullcone_copy_raid_modules "$newroot" "$initroot"','    fullcone_copy_raid_modules "$newroot" "$initroot" || return 1')
        t=replace(t,'    fullcone_copy_raid_modules "$newroot" "$initroot" || return 1','''    fullcone_copy_raid_modules "$newroot" "$initroot" || return 1
    uuid="$(awk '$1 == "option" && $2 == "uuid" { print $3; exit }' "$newroot/etc/config/mdadm")" || return 1
    printf '%s\\n' "$uuid" | grep -Eq '^[0-9a-fA-F]{8}(:[0-9a-fA-F]{8}){3}$' || return 1
    mkdir -p "$initroot/etc" || return 1
    mkdir -p "$initroot/run/mdadm" "$initroot/var" || return 1
    ln -sf /run "$initroot/var/run" || return 1
    printf 'DEVICE partitions\\nARRAY /dev/md/openwrt-root UUID=%s\\n' "$uuid" > "$initroot/etc/mdadm.conf" || return 1''')
        t=replace(t,'mdadm --assemble /dev/md/openwrt-root --scan --run 2>/tmp/mdadm.log || \\\nmdadm --assemble /dev/md/openwrt-root /dev/sd*2 /dev/vd*2 /dev/xvd*2 /dev/nvme*n*p2 /dev/mmcblk*p2 --run 2>>/tmp/mdadm.log','''mdadm --assemble --config=/etc/mdadm.conf --scan --run 2>/tmp/mdadm.log || {
    echo "Unable to assemble the configured RAID root; reboot inhibited"
    cat /tmp/mdadm.log
    while :; do sh; sleep 1; done
}''')
        t=replace(t,'    exec sh\n}', '    while :; do sh; sleep 1; done\n}')
        t=replace(t,'for mod in libcrc32c crc32c_generic md-mod raid1; do\n    find /lib/modules -name "$mod.ko" -type f -exec insmod {} \\; 2>/dev/null\ndone','''for mod in libcrc32c crc32c_generic md-mod raid1; do
    find /lib/modules -name "$mod.ko" -type f -exec insmod {} \\; 2>>/tmp/modules.log
done
grep -qw raid1 /proc/mdstat || {
    echo "RAID1 kernel modules are unavailable; reboot inhibited"
    cat /tmp/modules.log
    while :; do sh; sleep 1; done
}''')
        t=replace(t,'    chmod +x "$initroot/init"','    chmod +x "$initroot/init" || return 1\n    /bin/busybox chroot "$initroot" /bin/busybox true || return 1\n    /bin/busybox chroot "$initroot" /sbin/mdadm --version || return 1')
        t=replace(t,'    (cd "$initroot" && find . -print0 | cpio --null -o --format=newc | gzip -9) > "$output"','    (set -o pipefail; cd "$initroot" && find . -print0 | cpio -0 -o -H newc | gzip -9) > "$output" || return 1')
        for line in ['    rm -rf "$initroot"','    mkdir -p "$initroot/bin" "$initroot/sbin" "$initroot/proc" "$initroot/sys" "$initroot/dev" "$initroot/newroot" "$initroot/lib" "$initroot/tmp"','        ln -sf /bin/busybox "$initroot/bin/$app"','    ln -sf /bin/busybox "$initroot/sbin/$app"']:
            t=replace(t,line,line+' || return 1')
        t=replace(t,'    cat > "$initroot/init" <<\'RAIDINIT\'','    cat > "$initroot/init" <<\'RAIDINIT\' || return 1')
        return t
    s=function(s,'fullcone_build_raid_initramfs',raid_init)
    s+='\n'+(repo/'compile_script/fullcone_upgrade_runtime.sh').read_text()+'\n'
    path.write_text(s)

stage=Path('package/base-files/files/lib/upgrade/do_stage2');s=stage.read_text()
if MARK not in s:
    handler='''
# fullcone checked x86 sysupgrade 20261018
fullcone_stage2_abort() {
    v "Upgrade failed during $1. Automatic reboot inhibited; recovery data remains in /tmp."
    echo "Upgrade failed during $1; plan: $FULLCONE_UPGRADE_PLAN" >> /tmp/fullcone-upgrade-failure.log
    sync
    # procd upgraded reboots when this child exits, including on nonzero status.
    # Stay alive, keep its watchdog loop running, and offer local console recovery.
    while :; do
        [ ! -c /dev/console ] || /bin/ash -i </dev/console >/dev/console 2>&1
        sleep 1
    done
}

'''
    s=replace(s,'v "Performing system upgrade..."',handler+'v "Performing system upgrade..."')
    s=replace(s,'\tplatform_do_upgrade "$IMAGE"','''	if [ "${FULLCONE_GPT_UPGRADE_REQUIRED:-0}" = 1 ]; then
		platform_do_upgrade "$IMAGE" || fullcone_stage2_abort "firmware write/verification"
	else
		platform_do_upgrade "$IMAGE"
	fi''')
    s=replace(s,'\tplatform_copy_config','''	if [ "${FULLCONE_GPT_UPGRADE_REQUIRED:-0}" = 1 ]; then
		platform_copy_config || fullcone_stage2_abort "configuration backup copy"
	else
		platform_copy_config
	fi''')
    stage.write_text(s)
