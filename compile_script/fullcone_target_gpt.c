#define _FILE_OFFSET_BITS 64
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
/* Linux UAPI fs.h constants, guarded here to avoid kernel/musl ioctl macro
 * redefinitions and an unnecessary dependency on host kernel header packages. */
#ifndef BLKGETSIZE64
#define BLKGETSIZE64 _IOR(0x12,114,size_t)
#endif
#ifndef BLKSSZGET
#define BLKSSZGET _IO(0x12,104)
#endif
#ifndef BLKGETDISKSEQ
#define BLKGETDISKSEQ _IOR(0x12,128,uint64_t)
#endif

/* Validate independently of sgdisk: its verification command can return zero
 * for a damaged primary or backup. Never reconstruct a damaged primary. */
static uint64_t bytes;
static unsigned char *prefix;
static size_t prefix_size;
static void fail(const char *s) { fprintf(stderr,"GPT refused: %s\n",s); exit(1); }
static uint32_t u32(const unsigned char *p) { return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static uint64_t u64(const unsigned char *p) { return u32(p)|(uint64_t)u32(p+4)<<32; }
static uint32_t crc(const unsigned char *p,size_t n) { uint32_t c=~0U; while(n--) { c^=*p++; for(int i=0;i<8;i++) c=(c>>1)^(0xedb88320U & (0U-(c&1))); } return ~c; }
static void read_at(int fd,uint64_t pos,void *p,size_t n) {
  if(pos>bytes || n>bytes-pos) fail("metadata outside device");
  if(prefix) { if(pos>prefix_size || n>prefix_size-pos)fail("source metadata outside supported prefix");memcpy(p,prefix+pos,n);return; }
  unsigned char *out=p;
  while(n) { ssize_t k=pread(fd,out,n,(off_t)pos); if(k<=0) fail("metadata read failed"); pos+=(size_t)k;out+=k;n-=(size_t)k; }
}
struct gpt { unsigned char h[512],*table;size_t n;uint64_t lba,other,first,last; };
static struct gpt header(int fd,uint64_t lba) {
  struct gpt g={0}; unsigned char checked[512];
  read_at(fd,lba*512,g.h,512);
  if(memcmp(g.h,"EFI PART",8)) fail("missing GPT signature");
  uint32_t len=u32(g.h+12),count=u32(g.h+80),width=u32(g.h+84);
  if(u32(g.h+8)!=0x10000 || len<92 || len>512 || u32(g.h+20)) fail("unsupported header");
  memcpy(checked,g.h,len);memset(checked+16,0,4);
  if(crc(checked,len)!=u32(g.h+16)) fail("header CRC mismatch");
  g.lba=u64(g.h+24);g.other=u64(g.h+32);g.first=u64(g.h+40);g.last=u64(g.h+48);
  uint64_t table=u64(g.h+72);
  if(g.lba!=lba || g.other==lba || g.other>=bytes/512 || g.first>g.last || g.last>=bytes/512-1 || !count || count>4096 || width<128 || width>4096 || width%8) fail("invalid GPT geometry");
  g.n=(size_t)count*width;uint64_t sectors=(g.n+511)/512;
  if(g.first<2+sectors || (lba==1 ? (g.other<=g.last || sectors>=g.other-g.last) : g.other!=1)) fail("insufficient backup table space or invalid header pointer");
  if(table>=bytes/512 || sectors>bytes/512-table || (lba==1 ? (table<2 || table+sectors>g.first) : (table<=g.last || table+sectors>lba))) fail("invalid partition array bounds");
  g.table=malloc(g.n);if(!g.table) fail("allocation failed");read_at(fd,table*512,g.table,g.n);
  if(crc(g.table,g.n)!=u32(g.h+88)) fail("partition array CRC mismatch");
  for(uint32_t i=0;i<count;i++) { unsigned char *e=g.table+(size_t)i*width;unsigned char zero[16]={0};if(!memcmp(e,zero,16))continue;uint64_t a=u64(e+32),b=u64(e+40);if(a<g.first || a>b || b>g.last)fail("partition outside usable space");for(uint32_t j=0;j<i;j++) { unsigned char *q=g.table+(size_t)j*width;if(!memcmp(q,zero,16))continue;if(a<=u64(q+40) && u64(q+32)<=b)fail("overlapping partitions"); } }
  return g;
}
static void same(const struct gpt *a,const struct gpt *b) {
  if(a->n!=b->n || memcmp(a->h+56,b->h+56,16) || memcmp(a->table,b->table,a->n)) fail("partition GUIDs, bounds or entries changed/conflict");
}
int main(int argc,char **argv) {
  if(argc==4 && !strcmp(argv[1],"--source-check")) {
    char *end;bytes=strtoull(argv[2],&end,10);if(!*argv[2] || *end || bytes<34*512 || bytes%512)fail("invalid source size metadata");
    size_t limit=32*1024*1024;prefix=malloc(limit);if(!prefix)fail("allocation failed");unsigned char buf[65536];uint64_t total=0;size_t n;
    while((n=fread(buf,1,sizeof buf,stdin))) { if(total>bytes || n>bytes-total)fail("source exceeds declared size");if(total<limit) { size_t k=n;if(k>limit-(size_t)total)k=limit-(size_t)total;memcpy(prefix+(size_t)total,buf,k);prefix_size+=(size_t)k; }total+=n; }
    if(ferror(stdin) || total!=bytes)fail("source decompression/size mismatch");
    struct gpt p=header(-1,1);uint64_t root=strtoull(argv[3],&end,10);uint32_t width=u32(p.h+84);unsigned char zero[16]={0};
    if(!*argv[3] || *end || u32(p.h+80)<2 || !memcmp(p.table+width,zero,16) || u64(p.table+width+32)!=root)fail("root-start metadata disagrees with source GPT");
    free(p.table);free(prefix);puts("Verified source primary GPT before target writes");return 0;
  }
  int capacity=argc==4 && !strcmp(argv[1],"--target-check");
  int check=argc==3 && !strcmp(argv[1],"--check");
  if(!capacity && ((!check && argc!=2) || (check && argc!=3))) fail("usage: fullcone-target-gpt [--check] device");
  const char *path=argv[argc-1];int fd=open(path,O_RDONLY);if(fd<0) fail("open failed");struct stat st;if(fstat(fd,&st))fail("stat failed");
  if(S_ISBLK(st.st_mode)) { if(ioctl(fd,BLKGETSIZE64,&bytes))fail("device size unavailable");int sector;if(ioctl(fd,BLKSSZGET,&sector)||sector!=512)fail("only 512-byte logical sectors supported"); }
  else if(S_ISREG(st.st_mode)) bytes=(uint64_t)st.st_size;else fail("not a block device or image");
  if(bytes<34*512 || bytes%512)fail("unaligned or small device");
  if(capacity) { char *end;uint64_t needed=strtoull(argv[2],&end,10);if(!*argv[2] || *end || !needed || bytes<needed)fail("target smaller than source");close(fd);puts("Verified target capacity and logical sectors");return 0; }
  unsigned char boot[446],afterboot[446],raw[512],zero[512]={0};read_at(fd,0,boot,sizeof boot);
  struct gpt p=header(fd,1);read_at(fd,p.other*512,raw,512);int valid=memcmp(raw,zero,512)!=0;
  if(valid) { struct gpt b=header(fd,p.other);same(&p,&b);if(b.other!=1 || b.first!=p.first || b.last!=p.last)fail("GPT copies disagree");free(b.table); }
  if(check && (!valid || p.other!=bytes/512-1))fail("backup missing or not at device end");
  if(!valid || p.other!=bytes/512-1) {
    close(fd);pid_t pid=fork();if(pid<0)fail("fork failed");
    if(!pid) { execlp("sgdisk","sgdisk","-e",path,(char *)0);_exit(127); }
    int status;if(waitpid(pid,&status,0)!=pid || !WIFEXITED(status) || WEXITSTATUS(status))fail("sgdisk repair failed");
    fd=open(path,O_RDONLY);if(fd<0)fail("reopen failed");
  }
  struct gpt a=header(fd,1),b=header(fd,bytes/512-1);same(&p,&a);same(&a,&b);
  if(u64(p.h+72)!=u64(a.h+72)||u32(p.h+80)!=u32(a.h+80)||u32(p.h+84)!=u32(a.h+84))fail("primary entry position, count or width changed");
  if(a.other!=bytes/512-1 || b.other!=1 || a.first!=p.first || a.first!=b.first || a.last!=b.last)fail("backup repair postcondition failed");
  read_at(fd,0,afterboot,sizeof afterboot);
  if(memcmp(boot,afterboot,sizeof boot)) {
    /* sgdisk clears the legacy MBR disk signature (bytes 440..443).
     * Restore the original boot code/signature; leave its protective entry alone. */
    int out=open(path,O_WRONLY);if(out<0)fail("cannot preserve MBR boot code");
    if(pwrite(out,boot,sizeof boot,0)!=(ssize_t)sizeof boot || fsync(out))fail("MBR boot code preservation failed");
    close(out);read_at(fd,0,afterboot,sizeof afterboot);if(memcmp(boot,afterboot,sizeof boot))fail("MBR boot code changed");
  }
  free(p.table);free(a.table);free(b.table);close(fd);
  puts("Verified target GPT: primary CRC, backup CRC, GUIDs, partition entries and MBR boot code preserved");return 0;
}
