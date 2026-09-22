/*
 * tsp_crash.c  -  crash reporter for the OpenMW TrimUI port
 *
 * ===========================================================================
 * WHY THIS EXISTS
 * ===========================================================================
 *
 * Every fatal error on the device currently produces exactly this:
 *
 *     *** Fatal Error ***
 *      (signal 11)
 *     Address: 0x6e7b
 *
 *     Generating /tmp/openmw-crash.log and killing process 28283...
 *     gdb: error while loading shared libraries: libncursesw.so.5: ...
 *     sh: line 1: lldb: command not found
 *
 * That is not a crash report, it is a death notice. OpenMW's crash catcher
 * shells out to `gdb --pid N --quiet --batch --command ...` and then to
 * `lldb --attach-pid N ...`. Neither exists on this device, so the backtrace
 * is never produced and /tmp/openmw-crash.log is empty of anything useful.
 *
 * This library replaces that with a self-contained dump: no gdb, no lldb, no
 * external process. It writes signal, decoded si_code, faulting PC, an
 * unwound backtrace with module+offset per frame, the thread that died, the
 * memory state at the moment of death, and /proc/self/maps so the offsets can
 * be turned into source lines with addr2line off-device.
 *
 * ===========================================================================
 * THE THING THE CURRENT OUTPUT IS HIDING
 * ===========================================================================
 *
 * OpenMW prints a text description of si_code and NOTHING when it does not
 * recognise the value (components/crashcatcher: findSignalDescription returns
 * "" on no match, and the number itself is never printed). Of the three
 * fatal errors in tsp_prog.txt:
 *
 *   signal 4  Address: 0x2d45   no description   pid was 11589 = 0x2d45
 *   signal 11 "Address not mapped to object" Address: 0x2a3c
 *   signal 11 Address: 0x6e7b   no description   pid was 28283 = 0x6e7b
 *
 * Two of three printed an Address exactly equal to the process's own pid.
 * That is not a coincidence and it is not an address. In siginfo_t, si_addr
 * (the _sigfault member) and si_pid (the _kill member) occupy the same union
 * storage. They only alias like that when si_code is SI_USER, SI_TKILL or
 * SI_QUEUE - i.e. when the signal was SENT to the process rather than raised
 * by a hardware fault. A sent SIGSEGV or SIGILL with si_pid == getpid() means
 * something inside the process called raise()/pthread_kill() on itself.
 *
 * Only the middle one - SEGV_MAPERR at 0x2a3c - was a real memory fault.
 *
 * So the three deaths are probably NOT the same bug, and no amount of staring
 * at "Address: 0x6e7b" will say which is which. This library prints si_code
 * as a number and a name, and when si_code <= 0 it prints the sending pid and
 * uid and says plainly that si_addr is meaningless. That one line separates
 * "wild pointer" from "something deliberately killed us".
 *
 * ===========================================================================
 * THE SILENT DEATHS
 * ===========================================================================
 *
 * tsp_prog.txt holds 8 launches (8 x "frame=1 hook=SDL_GL_SwapWindow") but
 * only 3 fatal errors. The other 5 ended with no crash handler output at all.
 * A clean quit looks like that. So does SIGKILL from the OOM killer, which is
 * uncatchable and prints nothing anywhere in userspace.
 *
 * This library makes those distinguishable without guessing. It appends a
 * RUN line at startup and an EXIT line from atexit(). Read the log after the
 * fact:
 *
 *   RUN ... then EXIT      -> clean shutdown
 *   RUN ... then CRASH     -> caught, dumped below
 *   RUN ... then nothing   -> SIGKILL. Check `dmesg | grep -i "killed process"`.
 *                             On a 986MB device with zero swap that is the
 *                             OOM killer and it belongs to the memory hunt,
 *                             not to this one.
 *
 * ===========================================================================
 * v2 - WHY v1 CAUGHT NOTHING, AND WHAT CHANGED
 * ===========================================================================
 *
 * v1 was deployed and armed. Its log for the crashing run reads:
 *
 *   RUN    pid=9856 chain=1 maps=1
 *   SIGACTION intercepted SIGSEGV -> chaining to caller handler
 *   ... all five signals, twice each ...
 *
 * and then nothing. The same pid then died on signal 11 - OpenMW's own
 * catcher reported it and ran gdb against pid 9856. So the wrapper saw every
 * install, took over all five signals, and the handler still never wrote a
 * byte. v1 could not distinguish between "was replaced" and "could not be
 * entered", because it never looked again after installing.
 *
 * v2 stops assuming and starts checking:
 *
 *  1. READBACK. cr_verify() reads back what the kernel actually holds for all
 *     five signals at swaps 1, 2, 10, 60, 300 and every 1800 after. If the
 *     handler is not ours it logs HIJACK with the address, the owning module
 *     resolved via dladdr, and the flags - then reinstalls. This turns a
 *     silent replacement into a named one.
 *
 *  2. signal() IS NOW WRAPPED. glibc's signal() does not call the public
 *     sigaction symbol; it calls __sigaction internally and slips straight
 *     past an LD_PRELOAD sigaction wrapper. That is one of the very few ways
 *     a handler can be replaced leaving no trace, and v1 was blind to it.
 *
 *  3. THE ALTERNATE STACK. v1 installed with SA_ONSTACK and called
 *     sigaltstack() exactly once, in the constructor, on the main thread.
 *     sigaltstack is PER-THREAD. If the crashing thread had an alternate
 *     stack installed by something else that is too small, the handler faults
 *     on entry and writes nothing - which is precisely the observed symptom.
 *     v2 re-asserts its own stack, moved the two multi-KB buffers out of the
 *     handler's frame into static storage, and adds TSP_CRASH_NOALTSTACK=1 to
 *     remove SA_ONSTACK entirely as a controlled A/B.
 *
 *  4. INSTALLER IDENTITY. Every interception now logs which module supplied
 *     the handler and with which flags, so "who is fighting over SIGSEGV" is
 *     answerable from the log rather than by reasoning.
 *
 *  5. SELF TEST. TSP_CRASH_SELFTEST=N raises SIGSEGV at swap N. If no CRASH
 *     block follows the SELFTEST line, the handler is unreachable and every
 *     other conclusion drawn from this library is void. Run this once.
 *
 * None of the five is known to be the cause. They are the five ways the
 * observed silence is possible, and each now reports itself.
 *
 * ===========================================================================
 * v3 - WHAT THE FIRST TWO REAL CAPTURES SHOWED
 * ===========================================================================
 *
 * Two crashes were finally caught on the device. Both said the same thing:
 *
 *   CRASH pid=11434 tid=11568 t=151.5s        CRASH pid=13249 tid=13249 t=40.0s
 *     si_code 2 SEGV_ACCERR                     si_code 2 SEGV_ACCERR
 *     fault addr 0x7fabc0fbcc                   fault addr 0x7fb22beb74
 *     pc         0x7fabc0fbcc   <- EQUAL        pc         0x7fb22beb74  <- EQUAL
 *     lr 0x7fa9120e08                           lr 0x3a       <- garbage
 *     VmRSS 583060 kB                           VmRSS 585320 kB
 *     backtrace: <empty, dump truncated>        backtrace: <empty, truncated>
 *
 * pc == fault addr on both. SEGV_ACCERR means the page IS mapped and the
 * permission was wrong; when the offending address is the program counter,
 * the permission that was wrong is EXECUTE. The CPU jumped to an address it
 * is not allowed to execute. That is not a null-pointer read and it is not
 * memory exhaustion - MemAvailable was 175-181MB at both deaths, nowhere
 * near the cliff. It is a corrupted function pointer, vtable, or return
 * address. On the second, lr = 0x3a - a return address overwritten with the
 * integer 58.
 *
 * So the faulting instruction is not the bug. Whoever wrote the bad pointer
 * is, and that happened earlier and elsewhere. This is memory corruption.
 *
 * Both dumps also STOPPED at the "backtrace:" header. _Unwind_Backtrace
 * needs unwind info at the pc; the pc was garbage, so it faulted. The
 * recursion guard did not fire because SIGSEGV is blocked inside its own
 * handler and the kernel force-delivers the nested one straight to SIG_DFL,
 * killing the process instantly. v2 lost the maps and the END marker to this.
 *
 * v3 is built around that:
 *
 *  1. THE UNWINDER RUNS LAST. Everything safe is written before it, so its
 *     death costs nothing. TSP_CRASH_NOUNWIND=1 skips it entirely.
 *
 *  2. STACK SCAN. Walks raw words from sp and reports every one that dladdr
 *     resolves to a NAMED symbol. When the pc is garbage those words are the
 *     return addresses the smashed frame should have used - it is the only
 *     backtrace obtainable. Some entries are stale; that is the trade.
 *
 *  3. NOTHING IS DEREFERENCED UNCHECKED. cr_readable() write()s the address
 *     to /dev/null, which returns EFAULT for bad memory instead of faulting.
 *     Every pointer the dump touches is probed first.
 *
 *  4. SA_NODEFER, so a nested fault re-enters the handler and the recursion
 *     guard can actually print before exiting.
 *
 *  5. pc, lr and the fault address are each classified against dladdr and
 *     readability, and an explicit verdict is printed when pc == fault addr.
 *
 * WORTH TRYING BEFORE ANYTHING ELSE, no rebuild needed: run the game with
 *
 *     export MALLOC_CHECK_=3
 *     export MALLOC_PERTURB_=170
 *
 * MALLOC_CHECK_=3 makes glibc abort at the moment it detects a corrupt heap
 * rather than hours later, which converts this into a crash with a usable
 * backtrace. MALLOC_PERTURB_=170 fills freed memory with 0xAA, so a
 * use-after-free jumps to 0xaaaaaaaa... and says so in one glance. If the pc
 * in the next dump is a run of 0xaa, the answer is use-after-free and the
 * search is over.
 *
 * ===========================================================================
 * HOW IT GETS CONTROL
 * ===========================================================================
 *
 * OpenMW installs its handlers with sigaction() during startup, long after
 * an LD_PRELOAD constructor has run. A constructor-installed handler would
 * simply be overwritten and never fire.
 *
 * So sigaction() itself is wrapped. For the five fatal signals the wrapper
 * remembers the handler the caller asked for, installs this one instead, and
 * reports success. Everything else passes straight through untouched, which
 * matters because SDL installs its own handlers for SIGINT and SIGTERM and
 * must keep working.
 *
 * The remembered handler is then called after the dump is written, so
 * OpenMW's own crash path still runs and behaviour is otherwise unchanged.
 * TSP_CRASH_NOCHAIN=1 skips it and dies immediately via SIG_DFL instead -
 * much faster to iterate against, since the gdb/lldb attempts take seconds
 * and produce nothing.
 *
 * There is no per-frame cost. Nothing here runs during normal operation.
 *
 * ===========================================================================
 * ENVIRONMENT
 * ===========================================================================
 *
 *   TSP_CRASH_OUT=path   log, default /mnt/SDCARD/tsp_crash.txt (appended)
 *   TSP_CRASH_NOCHAIN=1  do not call OpenMW's handler; SIG_DFL + re-raise
 *   TSP_CRASH_MAPS=0     suppress the /proc/self/maps dump (it is ~30-60KB)
 *   TSP_CRASH_NOALTSTACK=1
 *                        install without SA_ONSTACK. See "v2" below - if a
 *                        crash is caught with this set and not without it,
 *                        the alternate signal stack was the problem.
 *   TSP_CRASH_SELFTEST=N raise(SIGSEGV) at swap number N. Proves the whole
 *                        path in situ. A CRASH block must follow the
 *                        SELFTEST line; if it does not, the handler is not
 *                        reachable and nothing else in this file is
 *                        trustworthy. Leave unset in normal use.
 *   TSP_CRASH_PROC=name  only arm in a process whose /proc/self/comm
 *                        contains this, default "openmw". The crash handler
 *                        spawns gdb, lldb and a shell, all of which inherit
 *                        LD_PRELOAD; without this every one of them appends
 *                        its own RUN line. That is the same subprocess noise
 *                        that already makes the scaler print its banner
 *                        three extra times per crash. "*" disables the filter.
 *   TSP_CRASH_OFF=1      disable entirely; sigaction() becomes a pure
 *                        pass-through and no file is opened
 *
 * ===========================================================================
 * READING THE OUTPUT
 * ===========================================================================
 *
 * Frames print as   module+file_offset (symbol+sym_offset).  The file offset
 * is what addr2line wants, not the runtime address:
 *
 *   arm-linux-gnueabihf-addr2line -f -C -e libGL.so.1.1 0x4a91c
 *
 * Run that against the UNSTRIPPED build of whichever module the frame names.
 * If the module is libGL.so.1 the crash is inside gl4es; if it is openmw the
 * crash is engine-side; if it is one of the libtsp_*.so shims it is ours.
 * That distinction is the entire point of this exercise.
 *
 * MAPS is dumped so a frame in a module you did not expect can still be
 * placed. Frames with no module are usually JIT/stripped or a corrupt stack.
 *
 * ===========================================================================
 * CAVEATS - THESE ARE REAL
 * ===========================================================================
 *
 * dladdr() and the unwinder take locks and are not async-signal-safe. If the
 * crash happened while holding one of those locks the dump can deadlock or
 * fault a second time. The recursion guard turns a second fault into a marker
 * line and an immediate _exit rather than a loop, and the header line is
 * written and flushed BEFORE any unsafe call, so even a dump that dies
 * halfway still tells you the signal, the code and the PC.
 *
 * An alternate signal stack is installed so that a stack overflow - which is
 * the one crash that cannot report itself on the normal stack - still dumps.
 *
 * The unwinder uses .eh_frame via libgcc rather than glibc's backtrace(),
 * which on ARM frequently returns one or two frames. Modules built without
 * unwind tables will still truncate the trace early; the PC and LR from the
 * signal context are printed separately for exactly that case and are always
 * correct.
 *
 * ===========================================================================
 * BUILD / DEPLOY
 * ===========================================================================
 *
 *   gcc -shared -fPIC -O2 -g -funwind-tables -o libtsp_crash.so tsp_crash.c \
 *       -ldl -lgcc_s
 *
 *   LD_PRELOAD="$GAMEDIR/lib/libtsp_crash.so:$GAMEDIR/lib/libtsp_diag.so:\
 *               $GAMEDIR/lib/libtsp_warm.so:\
 *               $GAMEDIR/lib/libtsp_fullscreen_scaler.so:$TSP_GL4ES_LIBRARY"
 *
 * FIRST in the list. It wraps sigaction and nothing else, so it does not sit
 * in any GL call path and cannot perturb what diag measures. Being first only
 * guarantees its constructor runs before anything else installs a handler.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>
#include <unwind.h>

/* ------------------------------------------------------------------ */
/* signal-safe output                                                  */
/*                                                                     */
/* Everything below writes with write(2) to a descriptor opened once at */
/* startup. No stdio: a FILE* buffer at crash time is a buffer you lose.*/
/* ------------------------------------------------------------------ */
static int  cr_fd  = -1;
static int  cr_off = 0;
static int  cr_nochain = 0;
static int  cr_maps = 1;
static int  cr_noaltstack;   /* TSP_CRASH_NOALTSTACK=1 drops SA_ONSTACK      */
static int  cr_nounwind;     /* TSP_CRASH_NOUNWIND=1 skips _Unwind_Backtrace */
static pid_t cr_pid;
static double cr_t0;

static void w(const char* s, size_t n)
{
    ssize_t r;
    if (cr_fd < 0 || !n) return;
    while (n) {
        r = write(cr_fd, s, n);
        if (r < 0) { if (errno == EINTR) continue; return; }
        s += r; n -= (size_t)r;
    }
}
static void ws(const char* s) { if (s) w(s, strlen(s)); }

static void wdec(long long v)
{
    char b[24]; int i = 24; int neg = (v < 0);
    unsigned long long u = neg ? (unsigned long long)(-(v + 1)) + 1ULL
                               : (unsigned long long)v;
    if (!u) b[--i] = '0';
    while (u) { b[--i] = (char)('0' + (int)(u % 10)); u /= 10; }
    if (neg) b[--i] = '-';
    w(b + i, (size_t)(24 - i));
}

static void whex(unsigned long long v)
{
    char b[16]; int i = 16;
    ws("0x");
    if (!v) { ws("0"); return; }
    while (v) { int d = (int)(v & 0xf); b[--i] = (char)(d < 10 ? '0'+d : 'a'+d-10); v >>= 4; }
    w(b + i, (size_t)(16 - i));
}

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

/* seconds since library init, one decimal, without floating point printf.
   now_ms() is milliseconds, so tenths-of-a-second is /100, not *10. */
static void w_elapsed(void)
{
    long long t = (long long)((now_ms() - cr_t0) / 100.0);
    if (t < 0) t = 0;
    wdec(t / 10); ws("."); wdec(t % 10);
}

/* Copy a proc file through. limit caps /proc/self/maps, which on a loaded
   OpenMW is 30-60KB and would otherwise dominate the log. */
static char cr_scratch[4096];   /* static, not stack: the handler may be running
                                   on an alternate signal stack whose size we do
                                   not control. A 4KB frame can overflow one. */

static void cat_file(const char* path, long limit, const char* prefix)
{
    char* buf = cr_scratch;
    const size_t bufsz = sizeof(cr_scratch) / 2;
    ssize_t n;
    long total = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) { ws(prefix); ws("  <unreadable: "); ws(path); ws(">\n"); return; }
    while ((n = read(fd, buf, bufsz)) > 0) {
        w(buf, (size_t)n);
        total += n;
        if (limit > 0 && total >= limit) { ws("\n... truncated at "); wdec(limit); ws(" bytes\n"); break; }
    }
    close(fd);
}

/* Pull one "Key:  value" line out of a proc file. Used for the handful of
   memory numbers that make a crash interpretable without cross-referencing
   tsp_diag.txt, which is itself truncated by the crash. */
static void w_proc_field(const char* path, const char* key)
{
    char* buf = cr_scratch;
    ssize_t n;
    char* p;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return;
    n = read(fd, buf, sizeof(cr_scratch) - 1);
    close(fd);
    if (n <= 0) return;
    buf[n] = 0;
    p = strstr(buf, key);
    if (!p) return;
    ws("  ");
    while (*p && *p != '\n') { w(p, 1); p++; }
    ws("\n");
}

/* Build "/proc/self/task/<tid>/comm" without snprintf. */
static void cr_task_comm_path(char* out, size_t n)
{
    static const char pre[] = "/proc/self/task/";
    char b[24]; int k = 24;
    long long t = (long long)syscall(SYS_gettid);
    size_t i = 0, j;
    if (n < sizeof(pre) + 30) { if (n) out[0] = 0; return; }
    for (j = 0; j < sizeof(pre) - 1; j++) out[i++] = pre[j];
    if (t <= 0) b[--k] = '0';
    while (t > 0) { b[--k] = (char)('0' + (int)(t % 10)); t /= 10; }
    while (k < 24) out[i++] = b[k++];
    out[i++] = '/'; out[i++] = 'c'; out[i++] = 'o';
    out[i++] = 'm'; out[i++] = 'm'; out[i] = 0;
}

/* ------------------------------------------------------------------ */
/* si_code decoding                                                    */
/*                                                                     */
/* The whole reason this file exists. OpenMW prints a name and drops    */
/* the number; anything it does not recognise prints as an empty string */
/* and the distinction between "faulted" and "was signalled" is lost.   */
/* ------------------------------------------------------------------ */
static const char* sig_name(int s)
{
    switch (s) {
        case SIGSEGV: return "SIGSEGV";
        case SIGILL:  return "SIGILL";
        case SIGBUS:  return "SIGBUS";
        case SIGFPE:  return "SIGFPE";
        case SIGABRT: return "SIGABRT";
        default:      return "?";
    }
}

/* si_code <= 0 means the signal was delivered by kill/tgkill/sigqueue rather
   than by the CPU; SI_KERNEL (0x80) means the kernel sent it without a fault.
   In every one of those cases si_addr is not an address at all - it aliases
   si_pid in the union. Returns 1 when that is so. */
static int code_is_sent(int code)
{
    return (code <= 0) || (code == SI_KERNEL);
}

static const char* code_name(int sig, int code)
{
    switch (code) {
        case SI_USER:    return "SI_USER (sent by kill())";
        case SI_KERNEL:  return "SI_KERNEL (sent by the kernel)";
        case SI_QUEUE:   return "SI_QUEUE (sent by sigqueue())";
        case SI_TIMER:   return "SI_TIMER";
        case SI_MESGQ:   return "SI_MESGQ";
        case SI_ASYNCIO: return "SI_ASYNCIO";
        case SI_SIGIO:   return "SI_SIGIO";
        case SI_TKILL:   return "SI_TKILL (sent by tgkill()/raise()/pthread_kill())";
        default: break;
    }
    if (sig == SIGSEGV) switch (code) {
        case SEGV_MAPERR: return "SEGV_MAPERR (address not mapped)";
        case SEGV_ACCERR: return "SEGV_ACCERR (no permission for mapped object)";
        default: return "unknown SIGSEGV code";
    }
    if (sig == SIGILL) switch (code) {
        case ILL_ILLOPC: return "ILL_ILLOPC (illegal opcode)";
        case ILL_ILLOPN: return "ILL_ILLOPN (illegal operand)";
        case ILL_ILLADR: return "ILL_ILLADR (illegal addressing mode)";
        case ILL_ILLTRP: return "ILL_ILLTRP (illegal trap)";
        case ILL_PRVOPC: return "ILL_PRVOPC (privileged opcode)";
        case ILL_PRVREG: return "ILL_PRVREG (privileged register)";
        case ILL_COPROC: return "ILL_COPROC (coprocessor error)";
        case ILL_BADSTK: return "ILL_BADSTK (internal stack error)";
        default: return "unknown SIGILL code";
    }
    if (sig == SIGBUS) switch (code) {
        case BUS_ADRALN: return "BUS_ADRALN (invalid address alignment)";
        case BUS_ADRERR: return "BUS_ADRERR (nonexistent physical address)";
        case BUS_OBJERR: return "BUS_OBJERR (object-specific hardware error)";
        default: return "unknown SIGBUS code";
    }
    if (sig == SIGFPE) switch (code) {
        case FPE_INTDIV: return "FPE_INTDIV (integer divide by zero)";
        case FPE_INTOVF: return "FPE_INTOVF (integer overflow)";
        case FPE_FLTDIV: return "FPE_FLTDIV (float divide by zero)";
        case FPE_FLTOVF: return "FPE_FLTOVF (float overflow)";
        case FPE_FLTUND: return "FPE_FLTUND (float underflow)";
        case FPE_FLTRES: return "FPE_FLTRES (inexact result)";
        case FPE_FLTINV: return "FPE_FLTINV (invalid operation)";
        case FPE_FLTSUB: return "FPE_FLTSUB (subscript out of range)";
        default: return "unknown SIGFPE code";
    }
    return "unknown code";
}

/* ------------------------------------------------------------------ */
/* backtrace                                                           */
/* ------------------------------------------------------------------ */
#define CR_MAXFRAMES 64
struct cr_bt { void* pc[CR_MAXFRAMES]; int n; };

static _Unwind_Reason_Code cr_trace_cb(struct _Unwind_Context* ctx, void* arg)
{
    struct cr_bt* s = (struct cr_bt*)arg;
    _Unwind_Ptr ip = _Unwind_GetIP(ctx);
    if (!ip) return _URC_END_OF_STACK;
    if (s->n >= CR_MAXFRAMES) return _URC_END_OF_STACK;
    s->pc[s->n++] = (void*)(uintptr_t)ip;
    return _URC_NO_REASON;
}

/* Name the module an arbitrary code pointer lives in. Used to say WHO installed
   a signal handler, which is the question v1 could not answer. */
static void w_modname(void* p)
{
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (!p) { ws("<null>"); return; }
    if (p == (void*)SIG_DFL) { ws("SIG_DFL"); return; }
    if (p == (void*)SIG_IGN) { ws("SIG_IGN"); return; }
    if (dladdr(p, &info) && info.dli_fname && info.dli_fname[0]) {
        ws(info.dli_fname);
        if (info.dli_sname && info.dli_sname[0]) { ws(":"); ws(info.dli_sname); }
    } else {
        ws("<unknown module>");
    }
}

/* module + file offset is what addr2line consumes. The runtime address is
   useless on a PIE/ASLR system, which is why it is printed second. */
static void w_frame(int idx, void* pc)
{
    Dl_info info;
    ws("  #"); if (idx < 10) ws(" "); wdec(idx); ws("  ");
    whex((unsigned long long)(uintptr_t)pc);
    memset(&info, 0, sizeof(info));
    if (dladdr(pc, &info) && info.dli_fname && info.dli_fname[0]) {
        ws("  ");
        ws(info.dli_fname);
        ws("+");
        whex((unsigned long long)((const char*)pc - (const char*)info.dli_fbase));
        if (info.dli_sname && info.dli_sname[0]) {
            ws("  (");
            ws(info.dli_sname);
            ws("+");
            whex((unsigned long long)((const char*)pc - (const char*)info.dli_saddr));
            ws(")");
        }
    } else {
        ws("  <no module - stripped, JIT, or corrupt stack>");
    }
    ws("\n");
}

/* ------------------------------------------------------------------ */
/* safe memory probing                                                 */
/*                                                                     */
/* With a corrupted pc and a garbage lr, every pointer in the dump is   */
/* suspect. Dereferencing one inside the handler kills the dump - and   */
/* because SIGSEGV is blocked while our handler runs, a nested fault is */
/* force-delivered and the process dies instantly with no second        */
/* chance. So: never touch an address without asking the kernel first.  */
/* write() to /dev/null returns EFAULT for unreadable memory instead of */
/* faulting, and discards whatever it can read.                         */
/* ------------------------------------------------------------------ */
static int cr_devnull = -1;

static int cr_readable(const void* p, size_t n)
{
    if (cr_devnull < 0 || !p) return 0;
    return write(cr_devnull, p, n) == (ssize_t)n;
}

static int cr_hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* ------------------------------------------------------------------
   Print the ONE /proc/self/maps line whose range contains addr.

   v3 dumped the whole maps file capped at 64KB and called it done. On a
   loaded OpenMW the table is far larger than that - the /dev/mali0
   allocations alone run to hundreds of lines - so the cap fell long before
   the region we actually needed. The first real crash reported
   "libtsp_diag.so+0x2cc5c", which is ~179KB into a module whose entire
   image is ~94KB, i.e. dladdr matched loosely and the true owner of the
   address was never identified. The maps dump that would have said so was
   truncated.

   Reading the line directly answers the only question that matters about a
   corrupt pc: what KIND of memory did control flow land in - a library's
   data, the heap, a thread stack, an anonymous JIT arena, or the GPU
   driver's mapping.
   ------------------------------------------------------------------ */
static void w_maps_lookup(const char* label, unsigned long addr)
{
    char line[256];
    char buf[1024];
    int  li = 0, found = 0, fd;
    ssize_t n;

    if (!addr) return;
    fd = open("/proc/self/maps", O_RDONLY);
    if (fd < 0) { ws("  MAP "); ws(label); ws("  <maps unreadable>\n"); return; }

    while (!found && (n = read(fd, buf, sizeof(buf))) > 0) {
        ssize_t i;
        for (i = 0; i < n && !found; i++) {
            if (buf[i] != '\n') {
                if (li < (int)sizeof(line) - 1) line[li++] = buf[i];
                continue;
            }
            line[li] = 0;
            {
                unsigned long s = 0, e = 0;
                int k = 0, d;
                while ((d = cr_hexval(line[k])) >= 0) { s = s * 16 + (unsigned)d; k++; }
                if (line[k] == '-') {
                    k++;
                    while ((d = cr_hexval(line[k])) >= 0) { e = e * 16 + (unsigned)d; k++; }
                    if (addr >= s && addr < e) {
                        ws("  MAP "); ws(label); ws("  "); ws(line); ws("\n");
                        found = 1;
                    }
                }
            }
            li = 0;
        }
    }
    close(fd);
    if (!found) { ws("  MAP "); ws(label); ws("  <no mapping contains this address>\n"); }
}

/* Say what an address IS. For a smashed pc this is the whole diagnosis:
   an address that resolves to a module but is not executable means control
   flow jumped into data. */
static void w_addr_class(const char* label, unsigned long a)
{
    Dl_info info;
    ws("  "); ws(label); ws(" "); whex((unsigned long long)a);
    if (!a) { ws("  <null>\n"); return; }
    if (a < 0x10000) { ws("  <near-NULL>\n"); return; }
    memset(&info, 0, sizeof(info));
    if (dladdr((void*)(uintptr_t)a, &info) && info.dli_fname && info.dli_fname[0]) {
        ws("  "); ws(info.dli_fname);
        ws("+"); whex((unsigned long long)(a - (unsigned long)(uintptr_t)info.dli_fbase));
        if (info.dli_sname && info.dli_sname[0]) {
            ws("  ("); ws(info.dli_sname);
            ws("+"); whex((unsigned long long)(a - (unsigned long)(uintptr_t)info.dli_saddr));
            ws(")");
        }
    } else {
        ws("  <no module: heap, stack, or anonymous mapping>");
    }
    ws(cr_readable((const void*)(uintptr_t)a, 1) ? "  [readable]" : "  [UNREADABLE]");
    ws("\n");
}

/* ------------------------------------------------------------------ */
/* stack scan - the backtrace that works when the unwinder cannot      */
/*                                                                     */
/* _Unwind_Backtrace needs valid unwind info at the pc. When the pc is  */
/* garbage it finds none and gives up - and on the two captured device  */
/* crashes it did worse than give up, it faulted and truncated the      */
/* dump. Walking the raw stack and reporting every word that resolves   */
/* to a module recovers the call chain anyway: those words are the      */
/* return addresses the corrupted frame was supposed to use.            */
/* Expect false positives. They are cheap; a missing backtrace is not.  */
/* ------------------------------------------------------------------ */
static void cr_stack_scan(unsigned long sp, int words)
{
    int i, found = 0;
    unsigned long* p = (unsigned long*)(uintptr_t)sp;
    if (!sp) { ws("    <no sp>\n"); return; }
    for (i = 0; i < words; i++) {
        Dl_info info;
        unsigned long v;
        if (!cr_readable(&p[i], sizeof(unsigned long))) break;
        v = p[i];
        if (v < 0x10000) continue;
        memset(&info, 0, sizeof(info));
        if (!dladdr((void*)(uintptr_t)v, &info)) continue;
        if (!info.dli_fname || !info.dli_fname[0]) continue;
        /* Module+offset is enough - it is exactly what addr2line consumes.
           Requiring a symbol name would drop almost every frame inside
           openmw itself, since dladdr only sees DYNAMIC symbols and the
           engine's own functions are not exported. */
        ws("    sp+"); whex((unsigned long long)(i * sizeof(unsigned long)));
        ws("  ");     whex((unsigned long long)v);
        ws("  ");     ws(info.dli_fname);
        ws("+");      whex((unsigned long long)(v - (unsigned long)(uintptr_t)info.dli_fbase));
        if (info.dli_sname && info.dli_sname[0]) { ws("  ("); ws(info.dli_sname); ws(")"); }
        ws("\n");
        if (++found >= 40) { ws("    <40 candidates, stopping>\n"); return; }
    }
    if (!found) ws("    <no resolvable code pointers on the stack>\n");
}

/* ------------------------------------------------------------------ */
/* saved handlers                                                      */
/* ------------------------------------------------------------------ */
static const int cr_signals[] = { SIGSEGV, SIGILL, SIGBUS, SIGFPE, SIGABRT };
#define CR_NSIG ((int)(sizeof(cr_signals)/sizeof(cr_signals[0])))

static struct sigaction cr_prev[CR_NSIG];
static int              cr_have_prev[CR_NSIG];

static int cr_slot(int sig)
{
    int i;
    for (i = 0; i < CR_NSIG; i++) if (cr_signals[i] == sig) return i;
    return -1;
}

/* This library exports sigaction(), so a plain call to sigaction() from
   inside it resolves back to our own wrapper through the PLT and recurses.
   Every internal install must go through this instead. */
static int (*real_sigaction)(int, const struct sigaction*, struct sigaction*) = NULL;

static int cr_real_sigaction(int sig, const struct sigaction* act,
                             struct sigaction* oldact)
{
    if (!real_sigaction)
        real_sigaction = (int (*)(int, const struct sigaction*, struct sigaction*))
                         dlsym(RTLD_NEXT, "sigaction");
    if (!real_sigaction) { errno = ENOSYS; return -1; }
    return real_sigaction(sig, act, oldact);
}

/* ------------------------------------------------------------------ */
/* the handler                                                         */
/* ------------------------------------------------------------------ */
static volatile sig_atomic_t cr_inside = 0;

static void cr_handler(int sig, siginfo_t* si, void* uctx)
{
    struct cr_bt bt;
    int i, slot;
    int code = si ? si->si_code : 0;
    unsigned long pc = 0, lr = 0, sp = 0;

    /* A fault inside the dump must not recurse. Say so and go. 128+sig is
       the shell's convention for death-by-signal. */
    if (cr_inside) {
        ws("\n[tsp_crash] FAULT INSIDE HANDLER - dump incomplete\n");
        _exit(128 + sig);
    }
    cr_inside = 1;

    /* The register names below are the only arch-specific code in this file.
       They are the standard glibc/musl spellings for arm, aarch64 and x86_64,
       but if the toolchain in openmw_builder disagrees, rebuild with
       -DTSP_CRASH_NO_UCONTEXT and everything else still works - you lose the
       pc/lr/sp line and keep the backtrace, which usually carries the same
       information one frame later. An unrecognised arch compiles fine and
       simply reports pc 0x0. */
#if !defined(TSP_CRASH_NO_UCONTEXT)
# if defined(__aarch64__)
    { ucontext_t* u = (ucontext_t*)uctx;
      if (u) { pc = (unsigned long)u->uc_mcontext.pc;
               sp = (unsigned long)u->uc_mcontext.sp;
               lr = (unsigned long)u->uc_mcontext.regs[30]; } }
# elif defined(__arm__)
    { ucontext_t* u = (ucontext_t*)uctx;
      if (u) { pc = (unsigned long)u->uc_mcontext.arm_pc;
               sp = (unsigned long)u->uc_mcontext.arm_sp;
               lr = (unsigned long)u->uc_mcontext.arm_lr; } }
# elif defined(__x86_64__)
    { ucontext_t* u = (ucontext_t*)uctx;
      if (u) { pc = (unsigned long)u->uc_mcontext.gregs[REG_RIP];
               sp = (unsigned long)u->uc_mcontext.gregs[REG_RSP]; } }
# else
    (void)uctx;
# endif
#else
    (void)uctx;
#endif

    /* ---------------------------------------------------------------
       Header first, before any call that could itself fault. If the
       dump dies below this point you still have the decisive facts.
       --------------------------------------------------------------- */
    ws("\n===============================================================\n");
    ws("CRASH  pid="); wdec((long long)cr_pid);
    ws(" tid=");       wdec((long long)syscall(SYS_gettid));
    ws(" t=");         w_elapsed(); ws("s\n");

    ws("  signal   "); wdec(sig); ws("  "); ws(sig_name(sig)); ws("\n");
    ws("  si_code  "); wdec(code); ws("  "); ws(code_name(sig, code)); ws("\n");

    if (si && code_is_sent(code)) {
        /* This is the case OpenMW renders as a bare "Address: 0x<pid>". */
        ws("  NOT A FAULT - this signal was SENT to the process.\n");
        ws("  sender pid="); wdec((long long)si->si_pid);
        ws(" uid=");         wdec((long long)si->si_uid);
        if (si->si_pid == cr_pid)
            ws("   <<<< SELF: raise()/pthread_kill() from inside this process");
        ws("\n");
        ws("  si_addr is meaningless here (it aliases si_pid in the union).\n");
    } else if (si) {
        ws("  fault addr "); whex((unsigned long long)(uintptr_t)si->si_addr);
        if ((uintptr_t)si->si_addr < 0x10000)
            ws("   <<<< near-NULL: unchecked allocation or freed object");
        ws("\n");
        /* The decisive distinction, and one nothing else prints. If the
           faulting address IS the program counter, the CPU did not fail to
           read or write data - it failed to EXECUTE. Control flow jumped to
           an address that is mapped but not executable, which only happens
           via a corrupted function pointer, vtable, or return address. */
        if ((unsigned long)(uintptr_t)si->si_addr == pc && pc != 0) {
            ws("  >>> pc == fault addr: EXECUTE fault, not a data access.\n");
            ws("  >>> Control flow jumped into non-executable memory.\n");
            ws("  >>> Cause is a corrupt function pointer / vtable / return\n");
            ws("  >>> address, i.e. memory corruption upstream of this point.\n");
            ws("  >>> The faulting instruction is NOT the bug; whoever wrote\n");
            ws("  >>> the bad pointer is. Read the stack scan below.\n");
        }
    }

    ws("  registers:\n");
    w_addr_class("pc", pc);
    w_addr_class("lr", lr);
    ws("  sp "); whex(sp); ws("\n");

    /* The owning mapping for each interesting address, read straight out of
       /proc/self/maps. dladdr can attribute an address to a module it is not
       actually inside; these lines cannot. */
    ws("  owning mappings:\n");
    w_maps_lookup("pc  ", pc);
    if (si && !code_is_sent(code))
        w_maps_lookup("addr", (unsigned long)(uintptr_t)si->si_addr);
    w_maps_lookup("lr  ", lr);
    w_maps_lookup("sp  ", sp);

    /* Thread identity. OSG names its threads, so this frequently answers
       "which subsystem" before the backtrace is even read. */
    ws("  thread   ");
    { char path[64], nb[64];
      int fd; ssize_t n;
      cr_task_comm_path(path, sizeof(path));
      fd = open(path, O_RDONLY);
      if (fd >= 0) { n = read(fd, nb, sizeof(nb) - 1); close(fd);
                     if (n > 0) { nb[n] = 0; w(nb, (size_t)n); } else ws("?\n"); }
      else ws("?\n"); }

    /* Memory at the instant of death. tsp_diag.txt cannot answer this: it
       flushes in batches and its tail is lost to the very crash being
       investigated. */
    ws("  memory at death:\n");
    w_proc_field("/proc/self/status",  "VmRSS:");
    w_proc_field("/proc/self/status",  "VmSize:");
    w_proc_field("/proc/meminfo",      "MemAvailable:");
    w_proc_field("/proc/meminfo",      "MemFree:");

    /* ---------------------------------------------------------------
       Unsafe from here down: the unwinder and dladdr both take locks.
       --------------------------------------------------------------- */
    /* ---------------------------------------------------------------
       ORDER MATTERS AND IT CHANGED IN v3.

       v2 ran the unwinder first and dumped maps after. On both captured
       device crashes the unwinder faulted on the corrupted pc and the dump
       stopped dead at the "backtrace:" header - no maps, no END CRASH,
       nothing. The recursion guard never fired either, because SIGSEGV is
       blocked inside its own handler and the kernel force-delivers the
       nested one straight to SIG_DFL.

       So everything safe now runs BEFORE the unwinder, and the unwinder
       runs last where its death costs nothing.
       --------------------------------------------------------------- */
    ws("  stack scan (raw words at sp that resolve to named code - these are\n"
       "             the return addresses the corrupted frame should have\n"
       "             used; expect some false positives):\n");
    cr_stack_scan(sp, 256);

    if (cr_maps) {
        /* 1MB, not 64KB. The v3 cap cut the table off well before the address
           under investigation - hundreds of /dev/mali0 lines come first. */
        ws("MAPS\n");
        cat_file("/proc/self/maps", 1048576, "");
    }

    if (cr_nounwind) {
        ws("  backtrace: skipped (TSP_CRASH_NOUNWIND=1)\n");
    } else {
        ws("  backtrace (LAST on purpose - if the dump ends here the unwinder\n"
           "             died on the corrupt pc, which is itself a finding.\n"
           "             Frames 0-1 are this handler and the signal trampoline):\n");
        bt.n = 0;
        _Unwind_Backtrace(cr_trace_cb, &bt);
        if (bt.n == 0) {
            ws("    <unwind produced nothing - use pc/lr and the stack scan>\n");
        } else {
            for (i = 0; i < bt.n; i++) w_frame(i, bt.pc[i]);
            if (bt.n < 3)
                ws("    <short trace: no unwind tables at the crashing pc>\n");
        }
    }
    ws("END CRASH\n");
    ws("===============================================================\n");

    /* ---------------------------------------------------------------
       Hand back. Chaining keeps OpenMW's crash path intact (it will
       still fail to find gdb, but nothing about the run changes).
       --------------------------------------------------------------- */
    slot = cr_slot(sig);
    if (!cr_nochain && slot >= 0 && cr_have_prev[slot]) {
        struct sigaction* p = &cr_prev[slot];
        if ((p->sa_flags & SA_SIGINFO) && p->sa_sigaction) {
            p->sa_sigaction(sig, si, uctx);
            return;
        }
        if (p->sa_handler && p->sa_handler != SIG_DFL && p->sa_handler != SIG_IGN) {
            p->sa_handler(sig);
            return;
        }
    }

    /* No chain: die the way the OS intended so the shell reports it. */
    { struct sigaction d;
      memset(&d, 0, sizeof(d));
      d.sa_handler = SIG_DFL;
      cr_real_sigaction(sig, &d, NULL); }
    raise(sig);
}

/* ------------------------------------------------------------------ */
/* installation                                                        */
/* ------------------------------------------------------------------ */
/* Not SIGSTKSZ: on glibc 2.34+ that is a sysconf() call, not a constant,
   and cannot size a static array. 64KB is ample for this handler. */
#define CR_ALTSTACK_SZ 65536
static char cr_altstack[CR_ALTSTACK_SZ];

/* sigaltstack() is per-thread. The constructor runs on the main thread only,
   so any other thread entering the handler with SA_ONSTACK set is relying on
   a stack this library never installed. If that stack is absent the flag is
   harmlessly ignored, but if it is present and too small the handler dies on
   entry and writes nothing - which is the observed failure. Re-assert ours,
   and provide TSP_CRASH_NOALTSTACK=1 to take SA_ONSTACK out of the picture
   entirely as an A/B. */
static void cr_assert_altstack(void)
{
    stack_t ss, old;
    memset(&old, 0, sizeof(old));
    if (sigaltstack(NULL, &old) == 0 && (old.ss_flags & SS_ONSTACK))
        return;                      /* currently executing on it; leave alone */
    ss.ss_sp    = cr_altstack;
    ss.ss_size  = sizeof(cr_altstack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);
}

static void cr_install_one(int sig)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = cr_handler;
    /* SA_NODEFER so a fault INSIDE the handler re-enters it and hits the
       recursion guard. Without it the nested SIGSEGV is blocked, the kernel
       force-delivers it to SIG_DFL, and the process dies mid-dump with no
       marker - which is what happened on both captured device crashes. */
    sa.sa_flags = SA_SIGINFO | SA_RESTART | SA_NODEFER;
    if (!cr_noaltstack) sa.sa_flags |= SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    cr_real_sigaction(sig, &sa, NULL);
}

static void cr_install_all(void)
{
    int i;
    cr_assert_altstack();
    for (i = 0; i < CR_NSIG; i++) {
        /* Record what was there first, so a chain target always exists and
           so the first caller that asks for oldact is told the truth rather
           than handed a pointer into this library. */
        if (cr_real_sigaction(cr_signals[i], NULL, &cr_prev[i]) == 0)
            cr_have_prev[i] = 1;
        cr_install_one(cr_signals[i]);
    }
}

/* ------------------------------------------------------------------ */
/* sigaction interception                                              */
/*                                                                     */
/* OpenMW installs its handlers well after our constructor runs, so a   */
/* constructor-only install is silently replaced and never fires. Take  */
/* the five fatal signals, remember what the caller wanted, and let     */
/* everything else through - SDL's SIGINT/SIGTERM handlers must survive.*/
/* ------------------------------------------------------------------ */
int sigaction(int sig, const struct sigaction* act, struct sigaction* oldact)
{
    int slot;

    if (cr_off || !act) return cr_real_sigaction(sig, act, oldact);

    slot = cr_slot(sig);
    if (slot < 0) return cr_real_sigaction(sig, act, oldact);

    /* Report the handler the caller last asked for, not ours, so anyone
       who saves and restores around a critical section gets back what
       they expect rather than a pointer into this library. */
    if (oldact) {
        if (cr_have_prev[slot]) *oldact = cr_prev[slot];
        else cr_real_sigaction(sig, NULL, oldact);
    }

    cr_prev[slot] = *act;
    cr_have_prev[slot] = 1;

    /* v1 logged only the signal name, so when the handler failed to fire there
       was no way to tell who had asked for what. Name the installer. */
    ws("SIGACTION "); ws(sig_name(sig));
    ws(" installer=");
    w_modname((void*)(uintptr_t)act->sa_sigaction);
    ws(" flags="); whex((unsigned long long)(unsigned)act->sa_flags);
    if (act->sa_flags & SA_ONSTACK)   ws(" ONSTACK");
    if (act->sa_flags & SA_RESETHAND) ws(" RESETHAND");
    if (act->sa_flags & SA_NODEFER)   ws(" NODEFER");
    ws(" -> ours installed, chaining to theirs\n");

    cr_install_one(sig);
    return 0;
}

/* glibc's signal() does NOT call the public sigaction symbol - it calls
   __sigaction internally, so it slips straight past the wrapper above. That is
   one of the few ways our handler could be replaced without leaving a trace,
   which is exactly the failure being investigated. Cover it. */
static void (*real_signal)(int, void (*)(int)) = NULL;

void (*signal(int sig, void (*handler)(int)))(int)
{
    struct sigaction sa, old;
    int slot;

    if (cr_off || cr_slot(sig) < 0) {
        if (!real_signal)
            real_signal = (void (*)(int, void (*)(int)))dlsym(RTLD_NEXT, "signal");
        if (real_signal) { real_signal(sig, handler); return NULL; }
        errno = ENOSYS;
        return SIG_ERR;
    }

    slot = cr_slot(sig);
    memset(&sa, 0, sizeof(sa));
    memset(&old, 0, sizeof(old));
    sa.sa_handler = handler;
    sa.sa_flags = SA_RESTART;
    sigemptyset(&sa.sa_mask);

    if (cr_have_prev[slot]) old = cr_prev[slot];
    cr_prev[slot] = sa;
    cr_have_prev[slot] = 1;

    ws("SIGNAL() "); ws(sig_name(sig));
    ws(" installer="); w_modname((void*)(uintptr_t)handler);
    ws(" -> ours installed, chaining to theirs\n");

    cr_install_one(sig);
    return old.sa_handler;
}

/* ------------------------------------------------------------------ */
/* handler readback verification                                       */
/*                                                                     */
/* v1 assumed that installing a handler meant keeping it. On the device */
/* a run intercepted all five signals, then crashed with SIGSEGV, and   */
/* wrote no dump at all - which can only mean the handler was gone or   */
/* could not be entered. Rather than theorise, read back what the       */
/* kernel actually holds and say so.                                    */
/* ------------------------------------------------------------------ */
static void cr_verify(unsigned long frame)
{
    int i, bad = 0;
    for (i = 0; i < CR_NSIG; i++) {
        struct sigaction cur;
        memset(&cur, 0, sizeof(cur));
        if (cr_real_sigaction(cr_signals[i], NULL, &cur) != 0) continue;
        if ((void*)(uintptr_t)cur.sa_sigaction == (void*)(uintptr_t)cr_handler)
            continue;
        bad++;
        ws("HIJACK f="); wdec((long long)frame);
        ws(" ");        ws(sig_name(cr_signals[i]));
        ws(" now=");    whex((unsigned long long)(uintptr_t)cur.sa_sigaction);
        ws(" ");        w_modname((void*)(uintptr_t)cur.sa_sigaction);
        ws(" flags=");  whex((unsigned long long)(unsigned)cur.sa_flags);
        ws("  -> reinstalling ours\n");
        cr_prev[i] = cur;
        cr_have_prev[i] = 1;
        cr_install_one(cr_signals[i]);
    }
    if (!bad) {
        ws("VERIFY f="); wdec((long long)frame);
        ws(" all five handlers still ours\n");
    }
}

/* Also re-assert the alternate stack. sigaltstack() is PER-THREAD: the
   constructor only ever set it on the main thread, so a handler installed
   with SA_ONSTACK entering on another thread has no stack we control. */
static void cr_assert_altstack(void);

static unsigned long cr_frame;
static long          cr_selftest;
static void (*real_SDL_GL_SwapWindow)(void*) = NULL;

void SDL_GL_SwapWindow(void* w)
{
    if (!real_SDL_GL_SwapWindow)
        real_SDL_GL_SwapWindow = (void (*)(void*))dlsym(RTLD_NEXT, "SDL_GL_SwapWindow");

    if (!cr_off && cr_fd >= 0) {
        cr_frame++;
        /* dense early, then rare: catches an installer that runs during
           startup as well as one that runs hours in, at no real cost */
        if (cr_frame == 1 || cr_frame == 2 || cr_frame == 10 || cr_frame == 60
            || cr_frame == 300 || (cr_frame % 1800) == 0) {
            if (cr_frame == 1) cr_assert_altstack();
            cr_verify(cr_frame);
        }
        if (cr_selftest > 0 && cr_frame == (unsigned long)cr_selftest) {
            ws("SELFTEST raising SIGSEGV at frame "); wdec((long long)cr_frame);
            ws(" - a CRASH block must follow this line\n");
            raise(SIGSEGV);
        }
    }

    if (real_SDL_GL_SwapWindow) real_SDL_GL_SwapWindow(w);
}

/* ------------------------------------------------------------------ */
/* lifecycle                                                           */
/* ------------------------------------------------------------------ */
static void cr_atexit(void)
{
    if (cr_fd < 0) return;
    ws("EXIT   pid="); wdec((long long)cr_pid);
    ws(" t=");         w_elapsed(); ws("s  clean shutdown\n");
}

/* gdb, lldb and the shell the crash handler spawns all inherit LD_PRELOAD.
   Without this filter each of them opens the log and appends a RUN line,
   which would bury the one process whose death is being investigated. */
static int cr_process_matches(const char* want)
{
    char comm[64];
    int fd; ssize_t n;
    if (!want || !want[0] || (want[0] == '*' && !want[1])) return 1;
    fd = open("/proc/self/comm", O_RDONLY);
    if (fd < 0) return 1;                 /* cannot tell: do not disarm */
    n = read(fd, comm, sizeof(comm) - 1);
    close(fd);
    if (n <= 0) return 1;
    comm[n] = 0;
    while (n > 0 && (comm[n-1] == '\n' || comm[n-1] == ' ')) comm[--n] = 0;
    return strstr(comm, want) != NULL;
}

__attribute__((constructor))
static void cr_init(void)
{
    const char* e;
    const char* path;

    e = getenv("TSP_CRASH_OFF");
    if (e && e[0] && e[0] != '0') { cr_off = 1; return; }

    e = getenv("TSP_CRASH_PROC");
    if (!e || !e[0]) e = "openmw";
    if (!cr_process_matches(e)) { cr_off = 1; return; }

    e = getenv("TSP_CRASH_NOCHAIN");    cr_nochain    = (e && e[0] && e[0] != '0');
    e = getenv("TSP_CRASH_NOALTSTACK"); cr_noaltstack = (e && e[0] && e[0] != '0');
    e = getenv("TSP_CRASH_NOUNWIND");   cr_nounwind   = (e && e[0] && e[0] != '0');
    e = getenv("TSP_CRASH_MAPS");    if (e && e[0] && e[0] == '0') cr_maps = 0;
    e = getenv("TSP_CRASH_SELFTEST"); if (e && e[0]) cr_selftest = atol(e);

    /* Opened before anything can crash: cr_readable() needs it. */
    cr_devnull = open("/dev/null", O_WRONLY);

    path = getenv("TSP_CRASH_OUT");
    if (!path || !path[0]) path = "/mnt/SDCARD/tsp_crash.txt";

    /* Appended, never truncated. A run that leaves a RUN line with no
       matching EXIT or CRASH was SIGKILLed, and that absence is the only
       evidence SIGKILL ever leaves. */
    cr_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (cr_fd < 0) return;

    cr_pid = getpid();
    cr_t0  = now_ms();

    ws("\nRUN    pid="); wdec((long long)cr_pid);
    ws(" v=4");
    ws(" chain=");       wdec(cr_nochain ? 0 : 1);
    ws(" maps=");        wdec(cr_maps);
    ws(" altstack=");    wdec(cr_noaltstack ? 0 : 1);
    ws(" selftest=");    wdec((long long)cr_selftest);
    ws("\n");
    ws("       a RUN with no later EXIT or CRASH was SIGKILLed"
       " (OOM killer leaves no other trace)\n");

    cr_install_all();
    atexit(cr_atexit);
}
