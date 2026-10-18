from pathlib import Path
import sys
config=Path(sys.argv[1]).read_text().splitlines()
manifests=list(Path(sys.argv[2]).glob('*.manifest'))
if not manifests: raise SystemExit('Missing firmware manifest')
features=['nikki','luci-app-nikki','luci-i18n-nikki-zh-cn','mihomo-meta','fullcone-flow','luci-app-accesspolicycontroller','tc-full','smartdns','luci-app-smartdns']
for path in manifests:
    packages={line.split(' - ',1)[0] for line in path.read_text().splitlines()}
    missing=[p for p in features if 'CONFIG_PACKAGE_'+p+'=y' in config and p not in packages]
    if missing: raise SystemExit(f'{path}: selected packages missing: {missing}')
print('Selected feature manifest validation passed')
