/*
 * tsp_prof.c  -  ptrace sampling profiler for OpenMW on the TrimUI
 *
 * ===========================================================================
 * WHY THIS
 * ===========================================================================
 *
 * Measured so far, during the spell/status-effect stall:
 *
 *   GPU              finish_us = 0.83 ms with a full flush   -> not the GPU
 *   submission       draws/verts within 5% of normal frames  -> not batching
 *   disk             zero D-state samples during the stall   -> not I/O
 *   frame accounting draw 3.7 + finish 0.8 + swap 5.3 ms,
 *                    but 108 ms unaccounted                  -> CPU-side
 *   thread state     main thread cycles rapidly between
 *                    running and futex waits                 -> lock traffic
 *
 * So the time is inside OpenMW's own per-frame work, with heavy short-lived
 * lock contention. Shell sampling of /proc cannot see which functions. This
 * samples the actual program counter and walks the frame-pointer chain, which
 * names them.
 *
 * The device has no perf binary, but the kernel supports ptrace, which is
 * simpler and sufficient for a sampling profiler.
 *
 * ===========================================================================
 * HOW IT WORKS
 * ===========================================================================
 *
 *   PTRACE_SEIZE the target thread once, then repeatedly:
 *     PTRACE_INTERRUPT -> waitpid -> read PC and x29 -> PTRACE_CONT
 *
 *   At each stop it records the PC and walks up to MAXDEPTH frames using the
 *   aarch64 frame-pointer convention:
 *     [fp + 0] = caller's fp
 *     [fp + 8] = return address
 *
 *   Addresses are written raw. Symbol resolution happens on the VM, where
 *   binutils exists and the unstripped binary lives - see tsp_prof_resolve.sh.
 *
 * ===========================================================================
 * USAGE
 * ===========================================================================
 *
 *   tsp_prof <pid|--main> [seconds] [hz]
 *
 *   tsp_prof --main 10 200      profile the main thread, 10s at 200 Hz
 *
 * Writes:
 *   /mnt/SDCARD/tsp_prof.txt    one line per sample: pc frame1 frame2 ...
 *   /mnt/SDCARD/tsp_maps.txt    the target's /proc/PID/maps for offsetting
 *
 * Sampling briefly stops the thread, so the game will run slower while this
 * is active. That is expected and does not distort *relative* results.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <sys/types.h>
#include <time.h>
#include <elf.h>

#define MAXDEPTH 12

/* aarch64 register set as exposed through NT_PRSTATUS */
struct arm64_regs {
    unsigned long long regs[31];
    unsigned long long sp;
    unsigned long long pc;
    unsigned long long pstate;
};

static pid_t find_openmw(void)
{
    FILE* f = popen("pidof openmw-0.51", "r");
    pid_t p = 0;
    if (f) { if (fscanf(f, "%d", &p) != 1) p = 0; pclose(f); }
    return p;
}

static int read_word(pid_t tid, unsigned long long addr, unsigned long long* out)
{
    errno = 0;
    long v = ptrace(PTRACE_PEEKDATA, tid, (void*)(unsigned long)addr, NULL);
    if (v == -1 && errno) return 0;
    *out = (unsigned long long)v;
    return 1;
}

int main(int argc, char** argv)
{
    pid_t target;
    int seconds = 10, hz = 200;
    long interval_us;
    FILE* out; FILE* mf;
    char path[256];
    long samples = 0, good = 0;
    struct timespec t_end, t_now;

    if (argc < 2) {
        fprintf(stderr, "usage: %s <pid|--main> [seconds] [hz]\n", argv[0]);
        return 1;
    }
    if (!strcmp(argv[1], "--main")) {
        target = find_openmw();
        if (!target) { fprintf(stderr, "openmw-0.51 not running\n"); return 1; }
    } else {
        target = (pid_t)atoi(argv[1]);
    }
    if (argc > 2) seconds = atoi(argv[2]);
    if (argc > 3) hz = atoi(argv[3]);
    if (hz < 1) hz = 1;
    if (hz > 1000) hz = 1000;
    interval_us = 1000000 / hz;

    printf("profiling tid %d for %ds at %d Hz\n", target, seconds, hz);

    /* snapshot the address map so the VM can offset addresses to the binary */
    snprintf(path, sizeof(path), "/proc/%d/maps", target);
    mf = fopen(path, "r");
    if (mf) {
        FILE* dst = fopen("/mnt/SDCARD/tsp_maps.txt", "w");
        char line[512];
        if (dst) {
            while (fgets(line, sizeof(line), mf)) fputs(line, dst);
            fclose(dst);
        }
        fclose(mf);
        printf("wrote /mnt/SDCARD/tsp_maps.txt\n");
    }

    if (ptrace(PTRACE_SEIZE, target, NULL, NULL) < 0) {
        perror("PTRACE_SEIZE");
        fprintf(stderr, "hint: run as root, and check /proc/sys/kernel/yama/ptrace_scope\n");
        return 1;
    }

    out = fopen("/mnt/SDCARD/tsp_prof.txt", "w");
    if (!out) { perror("open output"); ptrace(PTRACE_DETACH, target, NULL, NULL); return 1; }
    fprintf(out, "# ptrace samples: pc then frame-pointer chain, hex\n");

    clock_gettime(CLOCK_MONOTONIC, &t_end);
    t_end.tv_sec += seconds;

    for (;;) {
        struct arm64_regs regs;
        struct iovec iov;
        int status;
        unsigned long long fp, prev_fp, ra;
        int depth;

        clock_gettime(CLOCK_MONOTONIC, &t_now);
        if (t_now.tv_sec > t_end.tv_sec) break;

        if (ptrace(PTRACE_INTERRUPT, target, NULL, NULL) < 0) break;
        if (waitpid(target, &status, __WALL) < 0) break;
        samples++;

        iov.iov_base = &regs;
        iov.iov_len  = sizeof(regs);
        if (ptrace(PTRACE_GETREGSET, target, (void*)NT_PRSTATUS, &iov) == 0) {
            good++;
            fprintf(out, "%llx", regs.pc);

            fp = regs.regs[29];          /* aarch64 frame pointer */
            for (depth = 0; depth < MAXDEPTH && fp; depth++) {
                if (!read_word(target, fp + 8, &ra)) break;
                if (!ra) break;
                fprintf(out, " %llx", ra);
                if (!read_word(target, fp, &prev_fp)) break;
                if (prev_fp <= fp) break;   /* guard against loops */
                fp = prev_fp;
            }
            fputc('\n', out);
        }

        ptrace(PTRACE_CONT, target, NULL, NULL);
        usleep(interval_us);
    }

    ptrace(PTRACE_DETACH, target, NULL, NULL);
    fclose(out);
    printf("samples attempted=%ld captured=%ld\n", samples, good);
    printf("wrote /mnt/SDCARD/tsp_prof.txt\n");
    return 0;
}
