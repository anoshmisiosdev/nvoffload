#pragma once
#include <cstdarg>

// Logging for every nvoffload component. Level comes from NVOFFLOAD_LOG:
//   0 = silent, 1 = warnings (default), 2 = info, 3 = trace (per-frame; noisy)
namespace nvo {
enum class Level { Silent = 0, Warn = 1, Info = 2, Trace = 3 };
Level log_level();
void  log(Level lvl, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
}

#define NVO_WARN(...)  ::nvo::log(::nvo::Level::Warn,  __VA_ARGS__)
#define NVO_INFO(...)  ::nvo::log(::nvo::Level::Info,  __VA_ARGS__)
#define NVO_TRACE(...) ::nvo::log(::nvo::Level::Trace, __VA_ARGS__)
