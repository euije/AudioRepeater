/* Pixel 10 Android 17: direct PCM1 mmap transport, using the device TinyALSA. */
#include "tinyalsa_abi.h"
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <sound/asound.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

static unsigned int u32(const unsigned char *p) {
    return (unsigned int)p[0] | ((unsigned int)p[1]<<8) |
           ((unsigned int)p[2]<<16) | ((unsigned int)p[3]<<24);
}
static unsigned int u16(const unsigned char *p) { return p[0] | ((unsigned int)p[1]<<8); }
static int number(const char *s, unsigned int *n) {
    char *end; errno=0; unsigned long v=strtoul(s,&end,10);
    if(errno || !*s || *end || v>UINT_MAX) return -1;
    *n=(unsigned int)v; return 0;
}
static int32_t sample(const unsigned char *p, unsigned int bits) {
    if(bits==16) return (int32_t)(int16_t)u16(p)*65536;
    if(bits==24) {
        int32_t v=(int32_t)(u32((unsigned char[4]){p[0],p[1],p[2],0}));
        if(v&0x800000) v-=0x1000000;
        return v*256;
    }
    return (int32_t)u32(p);
}
static int status(int fd, struct snd_pcm_status *s) {
    memset(s,0,sizeof(*s)); return ioctl(fd,SNDRV_PCM_IOCTL_STATUS,s);
}

int main(int argc, char **argv) {
    FILE *f=NULL; void *lib=NULL; struct pcm *pcm=NULL;
    unsigned char *src=NULL; int32_t *dst=NULL;
    int rc=1, fd=-1; unsigned int card,dev,period,count,tail;
    unsigned int channels=0,bits=0,rate=0,align=0,bytes=0;
    long data_offset=-1; unsigned char header[40];
    if(argc!=7 || number(argv[2],&card) || number(argv[3],&dev) ||
       number(argv[4],&period) || number(argv[5],&count) || number(argv[6],&tail) ||
       card!=0 || dev!=1 || !period || !count || tail!=7200) {
        fprintf(stderr,"usage: player AGGREGATE_WAV 0 1 PERIOD COUNT 7200\n"); return 1;
    }
    f=fopen(argv[1],"rb");
    if(!f || fread(header,1,12,f)!=12 || memcmp(header,"RIFF",4) || memcmp(header+8,"WAVE",4)) goto done;
    while(fread(header,1,8,f)==8) {
        unsigned int n=u32(header+4); long next=ftell(f)+(long)n+(n&1);
        if(next<0) goto done;
        if(!memcmp(header,"fmt ",4)) {
            if(n<16 || fread(header,1,16,f)!=16 || u16(header)!=1) goto done;
            channels=u16(header+2); rate=u32(header+4); align=u16(header+12); bits=u16(header+14);
        } else if(!memcmp(header,"data",4)) { data_offset=ftell(f); bytes=n; }
        if(fseek(f,next,SEEK_SET)) goto done;
        if(channels && data_offset>=0) break;
    }
    if(rate!=48000 || (channels!=1 && channels!=2) ||
       (bits!=16 && bits!=24 && bits!=32) || align!=channels*(bits/8) ||
       data_offset<0 || !bytes || bytes%align) goto done;
    unsigned long long frames=bytes/align;
    if(frames<=tail) goto done;
    unsigned long long core=frames-tail;
    if(fseek(f,data_offset+(long)(core*align),SEEK_SET)) goto done;
    for(unsigned long long i=0;i<(unsigned long long)tail*align;i++) if(fgetc(f)!=0) goto done;
    if(fseek(f,data_offset,SEEK_SET)) goto done;

    lib=dlopen("/system/lib64/libtinyalsa.so",RTLD_NOW|RTLD_LOCAL);
    if(!lib) { fprintf(stderr,"TinyALSA load failed: %s\n",dlerror()); goto done; }
#define LOAD(name,type) type name=(type)dlsym(lib,#name); if(!name) goto done
    typedef struct pcm *(*open_fn)(unsigned int,unsigned int,unsigned int,struct pcm_config *);
    typedef int (*pcm_fn)(struct pcm *);
    typedef const char *(*error_fn)(struct pcm *);
    typedef unsigned int (*size_fn)(struct pcm *);
    typedef int (*write_fn)(struct pcm *,const void *,unsigned int);
    LOAD(pcm_open,open_fn); LOAD(pcm_close,pcm_fn); LOAD(pcm_is_ready,pcm_fn);
    LOAD(pcm_get_error,error_fn); LOAD(pcm_get_buffer_size,size_fn);
    LOAD(pcm_get_poll_fd,pcm_fn); LOAD(pcm_prepare,pcm_fn); LOAD(pcm_stop,pcm_fn);
    LOAD(pcm_mmap_write,write_fn);
    struct pcm_config cfg={.channels=2,.rate=rate,.period_size=period,.period_count=count,.format=PCM_FORMAT_S32_LE};
    pcm=pcm_open(card,dev,PCM_OUT|PCM_MMAP|PCM_NOIRQ,&cfg);
    if(!pcm || !pcm_is_ready(pcm)) {
        fprintf(stderr,"Unable to open PCM: %s\n",pcm?pcm_get_error(pcm):"NULL"); goto close_pcm;
    }
    fd=pcm_get_poll_fd(pcm);
    char fdpath[64],target[PATH_MAX]; snprintf(fdpath,sizeof(fdpath),"/proc/self/fd/%d",fd);
    ssize_t len=readlink(fdpath,target,sizeof(target)-1);
    if(len<0) goto close_pcm; target[len]=0;
    if(strcmp(target,"/dev/snd/pcmC0D1p")) goto close_pcm;
    printf("A2M_ALSA_MMAP_CONFIG api=pcm_mmap_write flags=MMAP|NOIRQ rate=%u channels=2 bits=32 source_channels=%u source_bits=%u\n",rate,channels,bits);
    printf("A2M_ALSA_PCM_FD_LIVE node=%s pid=%d\n",target,getpid()); fflush(stdout);
    unsigned int buffer=pcm_get_buffer_size(pcm);
    if(!buffer || buffer>UINT_MAX/8 || buffer>tail) goto close_pcm;
    src=malloc((size_t)buffer*align); dst=malloc((size_t)buffer*8);
    if(!src || !dst || pcm_prepare(pcm)) goto close_pcm;
    unsigned long long offset=0;
    while(offset<frames) {
        unsigned int n=(unsigned int)((frames-offset)>buffer?buffer:(frames-offset));
        if(fread(src,align,n,f)!=n) goto close_pcm;
        for(unsigned int i=0;i<n;i++) {
            const unsigned char *p=src+(size_t)i*align;
            dst[2*i]=sample(p,bits);
            dst[2*i+1]=channels==1?dst[2*i]:sample(p+bits/8,bits);
        }
        if(pcm_mmap_write(pcm,dst,n*8)) {
            fprintf(stderr,"Error playing sample: %s\n",pcm_get_error(pcm)); goto close_pcm;
        }
        offset+=n;
    }
    struct snd_pcm_status st;
    if(status(fd,&st)) goto close_pcm;
    if(st.state!=SNDRV_PCM_STATE_RUNNING || (unsigned long long)st.hw_ptr<core) {
        fprintf(stderr,"Mmap source not fully rendered: core=%llu hw_ptr=%llu state=%d\n",core,(unsigned long long)st.hw_ptr,st.state);
        goto close_pcm;
    }
    printf("A2M_ALSA_MMAP_RENDERED core_frames=%llu written_frames=%llu hw_frames=%llu\n",core,offset,(unsigned long long)st.hw_ptr);
    if(pcm_stop(pcm) || status(fd,&st) || st.state!=SNDRV_PCM_STATE_SETUP) goto close_pcm;
    printf("A2M_ALSA_MMAP_STOP state=SETUP\n"); fflush(stdout); rc=0;
close_pcm:
    if(pcm) { if(rc) pcm_stop(pcm); pcm_close(pcm); }
done:
    if(rc) fprintf(stderr,"A2M_ALSA_MMAP_FAILED errno=%d\n",errno);
    free(src); free(dst); if(lib) dlclose(lib); if(f) fclose(f); return rc;
}
