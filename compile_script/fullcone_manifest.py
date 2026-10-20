from pathlib import Path
import sys
config=Path(sys.argv[1]).read_text().splitlines()
manifests=list(Path(sys.argv[2]).glob('*.manifest'))
if not manifests: raise SystemExit('Missing firmware manifest')
features=['nikki', 'luci-app-nikki', 'luci-i18n-nikki-zh-cn', 'mihomo-meta', 'fullcone-flow', 'luci-app-accesspolicycontroller', 'tc-full', 'smartdns', 'luci-app-smartdns', 'fullcone-target-gpt', 'sgdisk']
for path in manifests:
    packages={line.split(' - ',1)[0] for line in path.read_text().splitlines()}
    missing=[p for p in features if 'CONFIG_PACKAGE_'+p+'=y' in config and p not in packages]
    if missing: raise SystemExit(f'{path}: selected packages missing: {missing}')

# fullcone BusyBox newc capability 20261018
if 'CONFIG_PACKAGE_fullcone-target-gpt=y' in config:
    prefix='CONFIG_BUSYBOX_CONFIG_' if 'CONFIG_BUSYBOX_CUSTOM=y' in config else 'CONFIG_BUSYBOX_DEFAULT_'
    for option in ['BUSYBOX','STTY','CPIO','FEATURE_CPIO_O','MDEV']:
        if prefix+option+'=y' not in config:
            raise SystemExit('Missing selected BusyBox initramfs capability: '+prefix+option)
    if prefix+'INSMOD=y' not in config and prefix+'MODPROBE_SMALL=y' not in config:
        raise SystemExit('Missing selected BusyBox module loading capability')

print('Selected feature manifest validation passed')
