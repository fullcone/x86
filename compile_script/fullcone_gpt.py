from pathlib import Path
import hashlib,json,struct,subprocess,sys,zlib
p=Path(sys.argv[1]); size=p.stat().st_size
if size%512: raise SystemExit('GPT image not sector aligned')
def header(f,lba):
    f.seek(lba*512); raw=f.read(512)
    if raw[:8]!=b'EFI PART': raise ValueError('Missing GPT header')
    length,crc=struct.unpack_from('<II',raw,12)
    if not 92<=length<=512: raise ValueError('Invalid GPT header size')
    data=bytearray(raw[:length]);data[16:20]=b'\0'*4
    if zlib.crc32(data)&0xffffffff!=crc: raise ValueError('Invalid GPT header CRC')
    current,backup,first,last=struct.unpack_from('<QQQQ',raw,24)
    table,count,width,crc=struct.unpack_from('<QIII',raw,72)
    if current!=lba or not 0<count<=4096 or not 128<=width<=4096: raise ValueError('Invalid GPT geometry')
    f.seek(table*512); entries=f.read(count*width)
    if len(entries)!=count*width or zlib.crc32(entries)&0xffffffff!=crc: raise ValueError('Invalid GPT table CRC')
    parts=[]
    for i in range(count):
        e=entries[i*width:(i+1)*width]
        if e[:16]==b'\0'*16:continue
        start,end=struct.unpack_from('<QQ',e,32)
        if not first<=start<=end<=last or end>=size//512-1: raise ValueError('Partition outside image')
        parts.append((start,end))
    return {'backup':backup,'guid':raw[56:72].hex(),'table':hashlib.sha256(entries).hexdigest(),'partitions':parts}
with p.open('rb') as f:
    primary=header(f,1)
    try:
        secondary=header(f,primary['backup'])
        if secondary['table']!=primary['table'] or secondary['guid']!=primary['guid']:raise SystemExit('Conflicting valid GPT copies')
        valid=True
    except ValueError:
        f.seek(primary['backup']*512); raw=f.read(512)
        if raw not in [b'',b'\0'*512]:raise SystemExit('Nonzero corrupt backup GPT requires investigation')
        valid=False
if not valid or primary['backup']!=size//512-1:
    print('::warning::Repairing missing/stale backup GPT on temporary decompressed copy only')
    subprocess.run(['sgdisk','-e',str(p)],check=True)
    with p.open('rb') as f: after=header(f,1); secondary=header(f,size//512-1)
    if any(after[k]!=primary[k] for k in ['guid','table','partitions']) or secondary['table']!=primary['table'] or after['backup']!=size//512-1:raise SystemExit('Unsafe or unsuccessful GPT repair')
print(json.dumps({'primary':primary,'backup_was_valid':valid,'original_compressed_payload_unchanged':True}))
