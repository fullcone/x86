#!/usr/bin/env python3
"""Stage the reviewed Netdata 1.38.1 source patch after feeds installation."""
from pathlib import Path
import re


def prepare(root=Path('.')):
    package = root / 'feeds/packages/admin/netdata'
    recipe = package / 'Makefile'
    text = recipe.read_text(encoding='utf8')
    if not re.search(r'^PKG_VERSION:=1\.38\.1$', text, re.M):
        raise SystemExit('Netdata lifecycle patch requires review for the selected version')
    if not re.search(r'^PKG_HASH:=e32a5427f0c00550210dbbf0046c2621313955256edf836db686e2bc270b8d10$', text, re.M):
        raise SystemExit('Unexpected Netdata source archive hash')
    destination = package / 'patches/005-fullcone-metadata-shutdown-lifecycle.patch'
    patch = Path(__file__).with_name('fullcone_netdata_lifecycle.patch').read_bytes()
    staged = destination.exists()
    if staged and destination.read_bytes() != patch:
        raise SystemExit('Refusing to overwrite a different Netdata lifecycle patch')
    # APK requires a numeric release: r3.fullcone1 is rejected. Fresh upstream
    # release 4 still needs review; only our matching staged patch can reuse it.
    release = re.search(r'^PKG_RELEASE:=(\S+)$', text, re.M)
    if not release or not (release[1] == '3' or (staged and release[1] in ('3.fullcone1', '4'))):
        raise SystemExit('Netdata package release requires review')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(patch)
    text = re.sub(r'^PKG_RELEASE:=\S+$', 'PKG_RELEASE:=4', text, flags=re.M)
    recipe.write_text(text, encoding='utf8', newline='\n')
    print('Staged Netdata lifecycle fix; Netdata remains enabled')


if __name__ == '__main__':
    prepare()
