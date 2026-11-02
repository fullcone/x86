from pathlib import Path
import hashlib,re
recipe=Path('feeds/packages/lang/rust/Makefile').read_text()
def field(name):
    match=re.search(r'^'+name+r'\s*:=\s*(\S+)',recipe,re.M)
    if not match:raise SystemExit('Rust recipe missing '+name)
    return match.group(1)
version=field('PKG_VERSION')
source=field('PKG_SOURCE').replace('$(PKG_VERSION)',version)
expected=field('PKG_HASH').lower()
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]*',source) or not re.fullmatch(r'[0-9a-f]{64}',expected):
    raise SystemExit('Unsupported Rust source filename or unverified recipe hash')
path=Path('dl')/source
if not path.is_file() or path.stat().st_size==0:raise SystemExit('Required Rust source missing after download: '+str(path))
h=hashlib.sha256()
with path.open('rb') as f:
    for data in iter(lambda:f.read(8*1024*1024),b''):h.update(data)
if h.hexdigest()!=expected:raise SystemExit('Rust source SHA256 mismatch: '+str(path))
print('Verified Rust source: '+str(path)+' sha256='+h.hexdigest())
