// LD_PRELOAD shim: refuse MADV_HUGEPAGE (14) and MADV_COLLAPSE (25) so that
// memory stays on 4 KiB pages even when THP is available (experiment only).
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stddef.h>
int madvise(void *addr, size_t len, int advice) {
    static int (*real)(void *, size_t, int) = 0;
    if (advice == 14 || advice == 25) { errno = EINVAL; return -1; }
    if (!real) real = (int (*)(void *, size_t, int))dlsym(RTLD_NEXT, "madvise");
    return real(addr, len, advice);
}
