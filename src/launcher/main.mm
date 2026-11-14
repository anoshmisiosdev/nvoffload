// nvprime-run: launch an app with libnvoffload.dylib injected, or print the GPU/driver picture (--info).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "diag/nvo_diag.h"
#include "common/nvo_env.h"
#include "common/nvo_log.h"
#include <sys/sysctl.h>
#include <mach-o/dyld.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static void usage(const char *argv0) {
    fprintf(stderr,
        "usage: %s --info\n"
        "       %s [options] <executable or .app> [args...]\n"
        "\n"
        "options:\n"
        "  --info                 print Metal devices, PCI/IOKit graphics tree, displays, NullMoth state; exit\n"
        "  --device=<policy>      nvidia (default) | default | intel | registry:0x<id> | <name substring>\n"
        "  --no-bridge            do not bridge CAMetalLayer presentation across GPUs\n"
        "  --trace                log every CAMetalLayer nextDrawable/present (NVOFFLOAD_TRACE_PRESENT=1)\n"
        "  --log=<0-3>            nvoffload verbosity (default 1)\n"
        "  --lib=<path>           libnvoffload.dylib to inject (default: next to this binary or ../lib)\n"
        "  --dry-run              print the environment and command, do not exec\n",
        argv0, argv0);
}

static std::string self_dir() {
    char buf[4096]; uint32_t n = sizeof buf;
    if (_NSGetExecutablePath(buf, &n) != 0) return ".";
    std::string p = [[[NSString stringWithUTF8String:buf] stringByResolvingSymlinksInPath] stringByDeletingLastPathComponent].UTF8String;
    return p;
}

static std::string find_lib(const char *explicitPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    std::vector<std::string> cands;
    if (explicitPath && *explicitPath) cands.push_back(explicitPath);
    if (const char *e = getenv(NVO_ENV_LIB)) cands.push_back(e);
    std::string d = self_dir();
    cands.push_back(d + "/libnvoffload.dylib");
    cands.push_back(d + "/../lib/libnvoffload.dylib");
    cands.push_back("/usr/local/lib/libnvoffload.dylib");
    for (auto &c : cands) if ([fm fileExistsAtPath:@(c.c_str())]) return [[@(c.c_str()) stringByStandardizingPath] UTF8String];
    return "";
}

static std::string resolve_target(const char *t) {
    NSString *p = @(t);
    if ([p.pathExtension isEqualToString:@"app"]) {
        NSBundle *b = [NSBundle bundleWithPath:p];
        if (b.executablePath) return b.executablePath.UTF8String;
    }
    return t;
}

static void print_header(void) {
    char model[128] = {0}; size_t len = sizeof model; sysctlbyname("hw.model", model, &len, NULL, 0);
    char cpu[256] = {0}; len = sizeof cpu; sysctlbyname("machdep.cpu.brand_string", cpu, &len, NULL, 0);
    printf("nvprime-run --info\n");
    printf("macOS %s, SMBIOS %s\nCPU %s\n\n", [[NSProcessInfo processInfo] operatingSystemVersionString].UTF8String, model, cpu);
}

static void preflight(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:@"/Library/GPUBundles/NVMTLDriver.bundle"])
        NVO_WARN("NVMTLDriver.bundle not installed: no NullMoth Metal device; offload cannot work");
    @autoreleasepool {
        NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
        if (all.count == 0) NVO_WARN("no Metal devices at all");
        else if (all.count == 1) NVO_INFO("single Metal device (%s): device override is a no-op, bridge stays off", all[0].name.UTF8String);
        else NVO_INFO("%lu Metal devices; offload + bridge possible", (unsigned long)all.count);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *device = nullptr, *lib = nullptr, *logLevel = nullptr;
        bool info = false, noBridge = false, trace = false, dry = false;
        int i = 1;
        for (; i < argc; i++) {
            const char *a = argv[i];
            if (!strcmp(a, "--")) { i++; break; }
            if (a[0] != '-') break;
            if (!strcmp(a, "--info")) info = true;
            else if (!strncmp(a, "--device=", 9)) device = a + 9;
            else if (!strcmp(a, "--no-bridge")) noBridge = true;
            else if (!strcmp(a, "--trace")) trace = true;
            else if (!strncmp(a, "--log=", 6)) logLevel = a + 6;
            else if (!strncmp(a, "--lib=", 6)) lib = a + 6;
            else if (!strcmp(a, "--dry-run")) dry = true;
            else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(argv[0]); return 0; }
            else { fprintf(stderr, "unknown option %s\n", a); usage(argv[0]); return 2; }
        }
        if (logLevel) setenv(NVO_ENV_LOG, logLevel, 1);

        if (info) {
            print_header();
            nvo_print_metal_devices();      printf("\n");
            nvo_print_accelerators();       printf("\n");
            nvo_print_framebuffers();       printf("\n");
            nvo_print_pci_display_devices();printf("\n");
            nvo_print_displays();           printf("\n");
            nvo_print_nullmoth();
            return 0;
        }
        if (i >= argc) { usage(argv[0]); return 2; }

        std::string dylib = find_lib(lib);
        if (dylib.empty()) { fprintf(stderr, "libnvoffload.dylib not found (build it, or pass --lib / %s)\n", NVO_ENV_LIB); return 1; }
        preflight();

        // Environment for the child.
        std::string insert = dylib;
        if (const char *prev = getenv("DYLD_INSERT_LIBRARIES")) if (*prev) insert += std::string(":") + prev;
        setenv("DYLD_INSERT_LIBRARIES", insert.c_str(), 1);
        setenv(NVO_ENV_DEVICE, device ? device : "nvidia", 1);
        setenv(NVO_ENV_BRIDGE, noBridge ? "0" : "1", 1);
        if (trace) setenv(NVO_ENV_TRACE_PRESENT, "1", 1);
        if (!getenv(MVK_ENV_FORCE_LOW_POWER)) setenv(MVK_ENV_FORCE_LOW_POWER, "0", 1);
        // NullMoth's own NVMTL_* / NVK_* variables are inherited untouched.

        std::string target = resolve_target(argv[i]);
        std::vector<char *> args;
        args.push_back(const_cast<char *>(target.c_str()));
        for (int k = i + 1; k < argc; k++) args.push_back(argv[k]);
        args.push_back(nullptr);

        if (dry) {
            printf("DYLD_INSERT_LIBRARIES=%s\n%s=%s\n%s=%s\n%s=%s\nexec:", getenv("DYLD_INSERT_LIBRARIES"),
                   NVO_ENV_DEVICE, getenv(NVO_ENV_DEVICE), NVO_ENV_BRIDGE, getenv(NVO_ENV_BRIDGE),
                   MVK_ENV_FORCE_LOW_POWER, getenv(MVK_ENV_FORCE_LOW_POWER));
            for (char *a : args) if (a) printf(" %s", a);
            printf("\n");
            return 0;
        }
        NVO_INFO("exec %s with %s", target.c_str(), dylib.c_str());
        execvp(target.c_str(), args.data());
        perror("execvp");
        return 127;
    }
}
