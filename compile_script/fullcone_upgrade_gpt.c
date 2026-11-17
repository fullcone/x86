#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#define main target_gpt_main
#include "fullcone_target_gpt.c"
#undef main
#include <sys/mman.h>
#include <sys/sysmacros.h>
#include <errno.h>

#define PREFIX_BYTES 32768
#define TAIL_BYTES 65536
#define REGION_BYTES 16384
struct region { uint64_t offset; uint32_t length; unsigned char data[REGION_BYTES]; };
struct plan {
  unsigned char magic[8];uint32_t version,checksum;
  uint64_t dev,ino,rdev,diskseq,capacity,image_bytes;
  uint32_t image_gpt,regions;
  struct region old[4];
  unsigned char old_prefix[PREFIX_BYTES],old_tail[TAIL_BYTES],new_prefix[PREFIX_BYTES],new_tail[TAIL_BYTES];
};
static void write_at(int fd,uint64_t pos,const void *data,size_t n) {
  const unsigned char *p=data;
  while(n) { ssize_t k=pwrite(fd,p,n,(off_t)pos);if(k<=0)fail("metadata write failed");pos+=(size_t)k;p+=k;n-=(size_t)k; }
}
static int device(const char *path,struct stat *st,uint64_t *sequence) {
  int fd=open(path,O_RDONLY|O_CLOEXEC);if(fd<0 || fstat(fd,st))fail("cannot open upgrade target");
  *sequence=0;
  if(S_ISBLK(st->st_mode)) {
    int sector;char node[160];
    if(ioctl(fd,BLKGETSIZE64,&bytes)||ioctl(fd,BLKSSZGET,&sector)||sector!=512)fail("upgrade requires 512-byte logical sectors");
    const char *reject[]={"partition","md","dm"};
    for(size_t i=0;i<sizeof reject/sizeof *reject;i++) { snprintf(node,sizeof node,"/sys/dev/block/%u:%u/%s",major(st->st_rdev),minor(st->st_rdev),reject[i]);if(!access(node,F_OK))fail("upgrade GPT target is a partition, md array or device-mapper filesystem"); }
    if(ioctl(fd,BLKGETDISKSEQ,sequence))fail("upgrade target disk identity unavailable");
  } else if(S_ISREG(st->st_mode))bytes=(uint64_t)st->st_size;
  else fail("upgrade target must be a whole disk or isolated image");
  if(bytes<TAIL_BYTES || bytes%512)fail("invalid upgrade target capacity");
  return fd;
}
static void canonical(const struct gpt *g) {
  if(u64(g->h+72)!=2 || u32(g->h+80)!=128 || u32(g->h+84)!=128)fail("GPT layout incompatible with OpenWrt fixed entry offsets");
  unsigned char zero[16]={0};if(!memcmp(g->table,zero,16)||!memcmp(g->table+128,zero,16))fail("GPT source requires boot and root partitions");
  const unsigned char *root=g->table+128+16;
  if(memcmp(g->h+56,root,15)||g->h[71]!=0||root[15]!=2)fail("OpenWrt disk/root GUID relationship is invalid");
}
static int image_kind(int fd) {
  unsigned char mbr[512],sig[8];read_at(fd,0,mbr,512);read_at(fd,512,sig,8);
  if(mbr[510]!=0x55 || mbr[511]!=0xaa)fail("invalid boot signature");
  if(!memcmp(sig,"EFI PART",8))return 1;
  int entries=0;
  for(int i=0;i<4;i++) {
    const unsigned char *e=mbr+446+i*16;uint64_t first=u32(e+8),count=u32(e+12);
    if(e[4]==0xee)fail("protective MBR without a valid primary GPT");
    if(!e[4]&&!count)continue;
    if(!e[4]||!count||!first||first>=bytes/512||count>bytes/512-first)fail("invalid MBR partition bounds");
    for(int j=0;j<i;j++) { const unsigned char *q=mbr+446+j*16;uint64_t a=u32(q+8),n=u32(q+12);if(q[4]&&first<a+n&&a<first+count)fail("overlapping MBR partitions"); }
    entries++;
  }
  if(!entries || !mbr[446+4] || !mbr[462+4])fail("image must contain boot and root partitions");
  return 0;
}
static void region_add(struct plan *p,int fd,uint64_t offset,uint32_t length) {
  for(uint32_t i=0;i<p->regions;i++)if(p->old[i].offset==offset&&p->old[i].length==length)return;
  if(p->regions>=4 || length>REGION_BYTES)fail("unsupported old backup metadata geometry");
  struct region *r=&p->old[p->regions++];r->offset=offset;r->length=length;read_at(fd,offset,r->data,length);
}
static void old_backup(struct plan *plan,int fd,const struct gpt *primary,uint64_t lba) {
  unsigned char raw[512],zero[512]={0};read_at(fd,lba*512,raw,512);
  if(!memcmp(raw,zero,512))return;
  /* A declared backup must validate even if its signature was damaged.
   * An unclaimed disk-end sector is only a GPT candidate with its signature. */
  if(lba!=primary->other && memcmp(raw,"EFI PART",8))return;
  struct gpt backup=header(fd,lba);same(primary,&backup);
  if(backup.other!=1 || backup.first!=primary->first || backup.last!=primary->last || u32(backup.h+80)!=128 || u32(backup.h+84)!=128)fail("pre-existing GPT copies conflict");
  region_add(plan,fd,u64(backup.h+72)*512,(uint32_t)backup.n);region_add(plan,fd,lba*512,512);free(backup.table);
}
static void read_source(struct plan *p,uint64_t limit) {
  int image=memfd_create("fullcone-source-metadata",MFD_CLOEXEC);if(image<0)fail("cannot create metadata-only source view");
  unsigned char buffer[65536];ssize_t n;uint64_t total=0;size_t tail=0;
  while((n=read(STDIN_FILENO,buffer,sizeof buffer))>0) {
    if(total>limit || (uint64_t)n>limit-total)fail("new image exceeds target capacity");
    if(total<PREFIX_BYTES) { size_t k=(size_t)n;if(k>PREFIX_BYTES-(size_t)total)k=PREFIX_BYTES-(size_t)total;memcpy(p->new_prefix+(size_t)total,buffer,k); }
    if((size_t)n>=TAIL_BYTES) { memcpy(p->new_tail,buffer+(size_t)n-TAIL_BYTES,TAIL_BYTES);tail=TAIL_BYTES; }
    else { size_t keep=tail;if(keep>TAIL_BYTES-(size_t)n)keep=TAIL_BYTES-(size_t)n;memmove(p->new_tail,p->new_tail+tail-keep,keep);memcpy(p->new_tail+keep,buffer,(size_t)n);tail=keep+(size_t)n; }
    total+=(uint64_t)n;
  }
  if(n<0 || total<TAIL_BYTES || total%512)fail("source stream is truncated or not sector aligned");
  p->image_bytes=total;if(ftruncate(image,(off_t)total))fail("cannot size source metadata view");write_at(image,0,p->new_prefix,PREFIX_BYTES);write_at(image,total-TAIL_BYTES,p->new_tail,TAIL_BYTES);
  bytes=total;p->image_gpt=(uint32_t)image_kind(image);
  if(p->image_gpt) { struct gpt source=header(image,1);canonical(&source);if(source.other*512<total-TAIL_BYTES)fail("source backup outside supported OpenWrt image tail");unsigned char raw[512],zero[512]={0};read_at(image,source.other*512,raw,512);if(memcmp(raw,zero,512)) { struct gpt b=header(image,source.other);same(&source,&b);if(b.other!=1||b.first!=source.first||b.last!=source.last)fail("source GPT copies conflict");free(b.table); }free(source.table); }
  close(image);
}
static void read_preview(struct plan *p) {
  size_t done=0;
  while(done<PREFIX_BYTES) { ssize_t n=read(STDIN_FILENO,p->new_prefix+done,PREFIX_BYTES-done);if(n<=0)fail("source metadata preview truncated");done+=(size_t)n; }
  uint64_t extent=TAIL_BYTES;
  if(!memcmp(p->new_prefix+512,"EFI PART",8)) {
    uint64_t backup=u64(p->new_prefix+512+32);if(backup>=((uint64_t)1<<41))fail("source GPT preview extent unsupported");extent=(backup+1)*512;
  } else {
    for(unsigned i=0;i<4;i++) { const unsigned char *e=p->new_prefix+446+i*16;uint64_t end=(uint64_t)u32(e+8)+u32(e+12);if(end*512>extent)extent=end*512; }
  }
  int image=memfd_create("fullcone-source-preview",MFD_CLOEXEC);if(image<0||ftruncate(image,(off_t)extent))fail("cannot create metadata-only source preview");
  write_at(image,0,p->new_prefix,PREFIX_BYTES);bytes=extent;p->image_bytes=extent;p->image_gpt=(uint32_t)image_kind(image);
  if(p->image_gpt) { struct gpt source=header(image,1);canonical(&source);free(source.table); }
  close(image);
}

static void save_plan(struct plan *p,const char *path) {
  p->checksum=0;p->checksum=crc((const unsigned char *)p,sizeof *p);
  int out=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(out<0)fail("cannot create private upgrade plan");
  write_at(out,0,p,sizeof *p);if(fsync(out))fail("cannot flush upgrade plan");close(out);
}
static struct plan *load_plan(const char *path) {
  struct plan *p=calloc(1,sizeof *p);if(!p)fail("allocation failed");int in=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);struct stat ps;
  if(in<0||fstat(in,&ps)||ps.st_size!=(off_t)sizeof *p||ps.st_uid!=getuid()||(ps.st_mode&077))fail("missing or unsafe upgrade plan");
  size_t left=sizeof *p;unsigned char *dest=(unsigned char *)p;
  while(left) { ssize_t n=read(in,dest,left);if(n<=0)fail("upgrade plan read failed");dest+=n;left-=(size_t)n; }
  close(in);uint32_t expected=p->checksum;p->checksum=0;
  if((memcmp(p->magic,"FCGPTUP1",8)&&memcmp(p->magic,"FCGPTIM1",8)&&memcmp(p->magic,"FCGPTPV1",8)&&memcmp(p->magic,"FCGPTPI1",8))||p->version!=2||crc((const unsigned char *)p,sizeof *p)!=expected||p->regions>4||p->image_bytes<TAIL_BYTES)fail("corrupt upgrade plan");
  p->checksum=expected;return p;
}
static void image_prepare(const char *path,int preview) {
  struct plan *p=calloc(1,sizeof *p);if(!p)fail("allocation failed");memcpy(p->magic,preview?"FCGPTPI1":"FCGPTIM1",8);p->version=2;
  if(preview)read_preview(p);else read_source(p,(uint64_t)1<<50);
  save_plan(p,path);free(p);puts(preview?"Verified metadata preview only; cannot authorize writes":"Verified image-only source without treating an md filesystem as a partitioned disk");
}
static void prepare(const char *path,const char *outpath,int preview) {
  struct plan *p=calloc(1,sizeof *p);if(!p)fail("allocation failed");struct stat st;uint64_t seq;int fd=device(path,&st,&seq);
  memcpy(p->magic,preview?"FCGPTPV1":"FCGPTUP1",8);p->version=2;p->dev=st.st_dev;p->ino=st.st_ino;p->rdev=st.st_rdev;p->diskseq=seq;p->capacity=bytes;
  int old_gpt=image_kind(fd);
  if(old_gpt) { struct gpt old=header(fd,1);canonical(&old);old_backup(p,fd,&old,old.other);if(old.other!=bytes/512-1)old_backup(p,fd,&old,bytes/512-1);free(old.table); }
  else { unsigned char sig[8];read_at(fd,bytes-512,sig,8);if(!memcmp(sig,"EFI PART",8))fail("MBR target has an unowned GPT backup"); }
  read_at(fd,0,p->old_prefix,PREFIX_BYTES);read_at(fd,bytes-TAIL_BYTES,p->old_tail,TAIL_BYTES);close(fd);
  if(preview)read_preview(p);else read_source(p,p->capacity);
  save_plan(p,outpath);free(p);
  puts(preview?"Verified disk/source metadata preview only; cannot authorize writes":"Verified upgrade source and existing disk metadata; prepared read-only GPT plan");
}
static void finish(const char *path,const char *planpath) {
  struct plan *p=load_plan(planpath);if(memcmp(p->magic,"FCGPTUP1",8))fail("image-only plan cannot authorize whole-disk GPT completion");
  struct stat st;uint64_t seq;int fd=device(path,&st,&seq);
  if(p->dev!=(uint64_t)st.st_dev||p->ino!=(uint64_t)st.st_ino||p->rdev!=(uint64_t)st.st_rdev||p->diskseq!=seq||p->capacity!=bytes||p->image_bytes>bytes||p->image_bytes<TAIL_BYTES)fail("upgrade target identity or capacity changed");
  unsigned char current[PREFIX_BYTES];read_at(fd,0,current,sizeof current);if(memcmp(current,p->new_prefix,sizeof current))fail("written primary metadata differs from validated source");
  int kind=image_kind(fd);if(kind!=(int)p->image_gpt)fail("written partition format changed");
  if(kind) { struct gpt now=header(fd,1);canonical(&now);free(now.table); }
  unsigned char tail[TAIL_BYTES];read_at(fd,bytes-TAIL_BYTES,tail,sizeof tail);
  for(size_t i=0;i<TAIL_BYTES;i++) { uint64_t pos=bytes-TAIL_BYTES+i;unsigned char value=pos<p->image_bytes?p->new_tail[pos-(p->image_bytes-TAIL_BYTES)]:p->old_tail[i];if(tail[i]!=value)fail("disk tail differs from owned pre-upgrade/source snapshot"); }
  for(uint32_t i=0;i<p->regions;i++) { struct region *q=&p->old[i];if(q->length>REGION_BYTES||q->offset>bytes||q->length>bytes-q->offset)fail("invalid planned metadata range");uint64_t begin=q->offset;if(begin<p->image_bytes)begin=p->image_bytes;if(begin>=q->offset+q->length)continue;unsigned char data[REGION_BYTES];size_t count=(size_t)(q->offset+q->length-begin);read_at(fd,begin,data,count);if(memcmp(data,q->data+(size_t)(begin-q->offset),count))fail("old backup changed outside the authorized source write"); }
  close(fd);
  /* Only erase metadata proved to belong to the old disk and outside the new
   * image extent. No partition data from the new image can be touched. */
  int out=open(path,O_WRONLY|O_CLOEXEC);if(out<0)fail("cannot open target for GPT completion");unsigned char zero[REGION_BYTES]={0};
  for(uint32_t i=0;i<p->regions;i++) { struct region *q=&p->old[i];uint64_t begin=q->offset;if(begin<p->image_bytes)begin=p->image_bytes;if(begin<q->offset+q->length)write_at(out,begin,zero,(size_t)(q->offset+q->length-begin)); }
  if(fsync(out))fail("cannot flush old backup cleanup");
  close(out);
  fd=open(path,O_RDONLY|O_CLOEXEC);if(fd<0)fail("cannot verify backup cleanup");
  for(uint32_t i=0;i<p->regions;i++) { struct region *q=&p->old[i];uint64_t begin=q->offset;if(begin<p->image_bytes)begin=p->image_bytes;if(begin<q->offset+q->length) { unsigned char data[REGION_BYTES];size_t count=(size_t)(q->offset+q->length-begin);read_at(fd,begin,data,count);if(memcmp(data,zero,count))fail("old backup cleanup verification failed"); } }
  close(fd);
  if(kind) { char *args[]={"fullcone-target-gpt",(char *)path,NULL};if(target_gpt_main(2,args))fail("new GPT completion failed"); }
  fd=open(path,O_RDONLY|O_CLOEXEC);if(fd<0)fail("cannot verify completed upgrade");
  if(kind) { struct gpt done=header(fd,1);canonical(&done);if(memcmp(done.h+56,p->new_prefix+512+56,16)||memcmp(done.table,p->new_prefix+1024,done.n))fail("completed GPT differs from authorized image");free(done.table); }
  else { read_at(fd,0,current,sizeof current);if(memcmp(current,p->new_prefix,sizeof current))fail("MBR source metadata changed during completion"); }
  close(fd);
  puts("Verified whole-disk upgrade completion; only owned old GPT metadata was replaced");free(p);
}

static void part_range(const struct plan *p,unsigned part,uint64_t *offset,uint64_t *length) {
  if(!part) { *offset=0;*length=p->image_bytes;return; }
  uint64_t first,count;
  if(p->image_gpt) {
    if(part>128)fail("unsupported GPT partition index");
    const unsigned char *e=p->new_prefix+1024+(part-1)*128;unsigned char zero[16]={0};
    if(!memcmp(e,zero,16))fail("source partition is absent");
    first=u64(e+32);uint64_t last=u64(e+40);if(last<first)fail("invalid source partition size");count=last-first+1;
  } else {
    if(part>4)fail("unsupported MBR partition index");
    const unsigned char *e=p->new_prefix+446+(part-1)*16;
    if(!e[4])fail("source partition is absent");
    first=u32(e+8);count=u32(e+12);
  }
  if(!count||first>=p->image_bytes/512||count>p->image_bytes/512-first)fail("source partition outside validated image");
  *offset=first*512;*length=count*512;
}
static int destination(const char *path,unsigned part,const struct plan *p,uint64_t length) {
  if(memcmp(p->magic,"FCGPTUP1",8)&&memcmp(p->magic,"FCGPTIM1",8))fail("metadata preview cannot authorize any destination check or write");
  struct stat st;uint64_t sequence=0;
  if(!part) {
    if(memcmp(p->magic,"FCGPTUP1",8))fail("image-only plan cannot authorize whole-disk writes");
    int fd=device(path,&st,&sequence);
    if(p->dev!=(uint64_t)st.st_dev||p->ino!=(uint64_t)st.st_ino||p->rdev!=(uint64_t)st.st_rdev||p->diskseq!=sequence||p->capacity!=bytes)fail("whole-disk write target identity changed");
    unsigned char prefix_now[PREFIX_BYTES],tail[TAIL_BYTES];read_at(fd,0,prefix_now,sizeof prefix_now);read_at(fd,bytes-TAIL_BYTES,tail,sizeof tail);
    if(memcmp(prefix_now,p->old_prefix,sizeof prefix_now)||memcmp(tail,p->old_tail,sizeof tail))fail("disk metadata changed since upgrade preparation");
    for(uint32_t i=0;i<p->regions;i++) { const struct region *q=&p->old[i];unsigned char data[REGION_BYTES];if(q->length>REGION_BYTES)fail("invalid old metadata region");read_at(fd,q->offset,data,q->length);if(memcmp(data,q->data,q->length))fail("old backup changed before write"); }
    close(fd);
  } else {
    int fd=open(path,O_RDONLY|O_CLOEXEC);if(fd<0||fstat(fd,&st))fail("cannot open partition/filesystem destination");
    if(S_ISBLK(st.st_mode)) {
      char node[160];int sector;if(ioctl(fd,BLKGETSIZE64,&bytes)||ioctl(fd,BLKSSZGET,&sector)||sector<=0||length%(unsigned)sector)fail("invalid filesystem destination geometry");
      int allowed=0;const char *kind[]={"partition","md","dm"};
      for(size_t i=0;i<sizeof kind/sizeof *kind;i++) { snprintf(node,sizeof node,"/sys/dev/block/%u:%u/%s",major(st.st_rdev),minor(st.st_rdev),kind[i]);if(!access(node,F_OK)) { if(i&&part!=2)fail("md/dm filesystem destination is only valid for root partition");allowed=1; } }
      if(!allowed)fail("partition copy must not overwrite a whole physical disk");
      if(!memcmp(p->magic,"FCGPTUP1",8)&&(ioctl(fd,BLKGETDISKSEQ,&sequence)||sequence!=p->diskseq))fail("partition belongs to a different disk");
    } else if(S_ISREG(st.st_mode))bytes=(uint64_t)st.st_size;
    else fail("invalid filesystem destination");
    close(fd);
  }
  if(length>bytes)fail("image partition exceeds destination capacity");
  return 0;
}
static void stream_write(const char *path,const char *planpath,unsigned part,int check_only) {
  struct plan *p=load_plan(planpath);uint64_t offset,length;part_range(p,part,&offset,&length);destination(path,part,p,length);
  if(check_only) { free(p);puts("Verified image range and destination capacity/type");return; }
  unsigned char first[PREFIX_BYTES],buf[65536];size_t done=0;
  while(done<sizeof first) { ssize_t n=read(STDIN_FILENO,first+done,sizeof first-done);if(n<=0)fail("source prefix truncated");done+=(size_t)n; }
  if(memcmp(first,p->new_prefix,sizeof first))fail("source changed since validation");
  int out=open(path,O_WRONLY|O_CLOEXEC);if(out<0)fail("cannot open validated destination for writing");uint64_t total=0;size_t nbytes=sizeof first;const unsigned char *data=first;
  for(;;) {
    if(total>p->image_bytes||nbytes>p->image_bytes-total)fail("source grew since validation");
    uint64_t begin=total>offset?total:offset,end=total+nbytes;if(end>offset+length)end=offset+length;
    if(begin<end)write_at(out,begin-offset,data+(size_t)(begin-total),(size_t)(end-begin));
    total+=nbytes;
    ssize_t n=read(STDIN_FILENO,buf,sizeof buf);if(n<0)fail("source read error");if(!n)break;nbytes=(size_t)n;data=buf;
  }
  if(total!=p->image_bytes)fail("source truncated since validation");
  if(fsync(out))fail("destination flush failed");
  if(close(out))fail("destination close failed");
  free(p);puts("Verified source length and checked write; bounded copies drained the source without masking decompression errors");
}
static int partition_device(const char *path,const struct plan *p) {
  if(memcmp(p->magic,"FCGPTUP1",8))fail("partition metadata completion requires a real disk plan");
  struct stat st;uint64_t seq;int fd=device(path,&st,&seq);
  if(p->dev!=(uint64_t)st.st_dev||p->ino!=(uint64_t)st.st_ino||p->rdev!=(uint64_t)st.st_rdev||p->diskseq!=seq||p->capacity!=bytes)fail("partition upgrade disk identity changed");
  unsigned char data[PREFIX_BYTES];read_at(fd,0,data,sizeof data);
  if(!memcmp(p->old_prefix+512,"EFI PART",8)) {
    struct gpt g=header(fd,1);canonical(&g);free(g.table);
    if(memcmp(data+512,p->old_prefix+512,512+16384))fail("partition-preserving upgrade altered primary GPT or extra entries");
  } else if(memcmp(data+446,p->old_prefix+446,64))fail("partition-preserving upgrade altered MBR partition entries");
  for(uint32_t i=0;i<p->regions;i++) { const struct region *q=&p->old[i];if(q->length>REGION_BYTES)fail("invalid backup metadata region");unsigned char block[REGION_BYTES];read_at(fd,q->offset,block,q->length);if(memcmp(block,q->data,q->length))fail("partition-preserving upgrade altered backup GPT"); }
  return fd;
}
static void signature_write(const char *path,const char *planpath) {
  struct plan *p=load_plan(planpath);int fd=partition_device(path,p);unsigned char value[4];read_at(fd,440,value,4);close(fd);
  if(memcmp(value,p->old_prefix+440,4))fail("MBR signature changed before expected update");
  fd=open(path,O_WRONLY|O_CLOEXEC);if(fd<0)fail("cannot update MBR signature");write_at(fd,440,p->new_prefix+440,4);if(fsync(fd))fail("signature flush failed");close(fd);
  fd=open(path,O_RDONLY|O_CLOEXEC);if(fd<0)fail("cannot verify signature");read_at(fd,440,value,4);close(fd);if(memcmp(value,p->new_prefix+440,4))fail("signature verification failed");free(p);
}
static void partition_finish(const char *path,const char *planpath) {
  struct plan *p=load_plan(planpath);int fd=partition_device(path,p);unsigned char value[4];read_at(fd,440,value,4);close(fd);
  if(memcmp(value,p->new_prefix+440,4))fail("new MBR signature was not retained");
  free(p);puts("Verified preserved partition layout, GPT entries including extra data/BIOS slots, and image MBR signature");
}
static void partmap(const char *planpath,int old) {
  struct plan *p=load_plan(planpath);if(old&&memcmp(p->magic,"FCGPTUP1",8)&&memcmp(p->magic,"FCGPTPV1",8))fail("old partition map requires whole-disk plan");
  const unsigned char *data=old?p->old_prefix:p->new_prefix;int gpt=!memcmp(data+512,"EFI PART",8);unsigned maximum=gpt?15:4;
  for(unsigned part=1;part<=maximum;part++) {
    uint64_t first,count;
    if(gpt) { const unsigned char *e=data+1024+(part-1)*128;unsigned char zero[16]={0};if(!memcmp(e,zero,16))continue;first=u64(e+32);uint64_t last=u64(e+40);if(last<first)fail("invalid planned partition range");count=last-first+1; }
    else { const unsigned char *e=data+446+(part-1)*16;if(!e[4])continue;first=u32(e+8);count=u32(e+12); }
    printf("%2u %5llu %7llu\n",part,(unsigned long long)first,(unsigned long long)count);
  }
  free(p);
}
int main(int argc,char **argv) {
  if(argc==4&&!strcmp(argv[1],"--file-equal")) {
    int a=open(argv[2],O_RDONLY|O_CLOEXEC),b=open(argv[3],O_RDONLY|O_CLOEXEC);
    if(a<0||b<0)fail("cannot open configuration backup for comparison");
    unsigned char x[65536],y[65536];
    for(;;) {
      ssize_t nx=read(a,x,sizeof x);if(nx<0)fail("configuration backup read failed");
      size_t done=0;while(done<(size_t)nx) { ssize_t ny=read(b,y+done,(size_t)nx-done);if(ny<=0)fail("configuration backup differs");done+=(size_t)ny; }
      if(memcmp(x,y,(size_t)nx))fail("configuration backup differs");
      if(!nx) { ssize_t ny=read(b,y,1);if(ny!=0)fail("configuration backup differs");break; }
    }
    if(close(a)||close(b))fail("configuration backup close failed");
    return 0;
  }
  if(argc==2&&!strcmp(argv[1],"--version")) { puts("fullcone-target-gpt upgrade-plan-v2 20261018");return 0; }
  if(argc==4&&(!strcmp(argv[1],"--upgrade-prepare")||!strcmp(argv[1],"--preview-prepare"))) { prepare(argv[2],argv[3],!strcmp(argv[1],"--preview-prepare"));return 0; }
  if(argc==4&&!strcmp(argv[1],"--upgrade-finish")) { finish(argv[2],argv[3]);return 0; }
  if(argc==3&&(!strcmp(argv[1],"--image-prepare")||!strcmp(argv[1],"--image-preview"))) { image_prepare(argv[2],!strcmp(argv[1],"--image-preview"));return 0; }
  if(argc==3&&!strcmp(argv[1],"--same-format")) { struct plan *p=load_plan(argv[2]);if(memcmp(p->magic,"FCGPTUP1",8)&&memcmp(p->magic,"FCGPTPV1",8))fail("format comparison requires whole-disk plan");int same_format=(int)p->image_gpt==(!memcmp(p->old_prefix+512,"EFI PART",8));free(p);return same_format?0:2; }
  if(argc==4&&!strcmp(argv[1],"--signature-write")) { signature_write(argv[3],argv[2]);return 0; }
  if(argc==4&&!strcmp(argv[1],"--partition-finish")) { partition_finish(argv[3],argv[2]);return 0; }
  if(argc==4&&!strcmp(argv[1],"--partmap")) { if(strcmp(argv[3],"old")&&strcmp(argv[3],"source"))fail("invalid partmap selector");partmap(argv[2],!strcmp(argv[3],"old"));return 0; }
  if(argc==5&&(!strcmp(argv[1],"--stream-write")||!strcmp(argv[1],"--part-check"))) { char *end;unsigned long n=strtoul(argv[3],&end,10);if(!*argv[3]||*end||n>128)fail("invalid copy partition index");stream_write(argv[4],argv[2],(unsigned)n,!strcmp(argv[1],"--part-check"));return 0; }
  return target_gpt_main(argc,argv);
}
