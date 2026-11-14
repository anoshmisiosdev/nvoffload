#include "common/nvo_log.h"
#include <cstdio>
#include <cstdlib>
#include <mutex>

namespace nvo {

Level log_level() {
    static Level cached = [] {
        const char *e = getenv("NVOFFLOAD_LOG");
        if (!e || !*e) return Level::Warn;
        int v = atoi(e);
        if (v < 0) v = 0;
        if (v > 3) v = 3;
        return static_cast<Level>(v);
    }();
    return cached;
}

void log(Level lvl, const char *fmt, ...) {
    if (lvl > log_level()) return;
    static std::mutex m;
    std::lock_guard<std::mutex> g(m);
    fputs("[nvoffload] ", stderr);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

} // namespace nvo
