#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
// OSKext.h is not in the public SDK any more; the symbol is still exported by IOKit.framework.
extern "C" CFDictionaryRef OSKextCopyLoadedKextInfo(CFArrayRef kextIdentifiers, CFArrayRef infoKeys);
#import "diag/nvo_diag.h"
#import "diag/ioreg_util.h"
#include "common/nvo_env.h"
#include <sys/sysctl.h>
#include <cstdio>

extern "C" int csr_get_active_config(uint32_t *config);

static void check_path(const char *p, const char *what) {
    BOOL isDir = NO;
    BOOL ok = [[NSFileManager defaultManager] fileExistsAtPath:@(p) isDirectory:&isDir];
    printf("  %-8s %s  (%s)\n", ok ? "present" : "MISSING", p, what);
}

static void sysctl_int(const char *name) {
    int64_t v = 0; size_t len = sizeof v;
    if (sysctlbyname(name, &v, &len, NULL, 0) == 0) printf("  %-32s = %lld\n", name, (long long)v);
    else printf("  %-32s   (not present)\n", name);
}
static void sysctl_str(const char *name) {
    char buf[256] = {0}; size_t len = sizeof buf - 1;
    if (sysctlbyname(name, buf, &len, NULL, 0) == 0) printf("  %-32s = %s\n", name, buf);
    else printf("  %-32s   (not present)\n", name);
}

void nvo_print_nullmoth(void) {
    @autoreleasepool {
        printf("== NullMoth driver: files ==\n");
        check_path("/Library/GPUBundles/NVMTLDriver.bundle", "Metal plugin");
        check_path("/Library/GPUBundles/nvmtl", "NVK / translator install dir");
        check_path("/Library/Extensions/NVRM.kext", "resource manager kext");
        check_path("/Library/Extensions/NVRMFB.kext", "NVIDIA framebuffer kext");
        check_path("/Library/Extensions/NVRMAGDC.kext", "AGDC kext");
        check_path("/Library/Extensions/NMIntelFB.kext", "hybrid: Intel panel provider (optional)");
        check_path("/Library/Extensions/NMGopFB.kext", "hybrid: GOP panel provider (optional)");
        check_path("/Library/NullMoth", "firmware + state dir");
        check_path("/Library/NullMoth/os-major", "installed-for macOS major");

        printf("== NullMoth driver: loaded kexts ==\n");
        NSDictionary *loaded = CFBridgingRelease(OSKextCopyLoadedKextInfo(NULL, NULL));
        int n = 0;
        for (NSString *bid in [loaded.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            BOOL interesting = [bid hasPrefix:@"com.nullmoth."] || [bid containsString:@"Lilu"] || [bid containsString:@"WhateverGreen"]
                            || [bid containsString:@"AMFIPass"] || ([bid containsString:@"AppleIntel"] && [bid containsString:@"Graphics"])
                            || [bid containsString:@"IONDRVSupport"];
            if (!interesting) continue;
            n++;
            NSDictionary *info = loaded[bid];
            printf("  %-48s %s\n", bid.UTF8String, [info[@"CFBundleVersion"] description].UTF8String ?: "");
        }
        if (!n) printf("  (no com.nullmoth.* kext loaded)\n");
        BOOL nvrm = loaded[@"com.nullmoth.NVRM"] != nil;
        BOOL fb = loaded[@"com.nullmoth.NVRMFB"] != nil;
        printf("  NVRM loaded: %s   NVRMFB loaded: %s   (NVAccel is a class inside NVRM.kext, see IOAccelerators above)\n",
               nvrm ? "yes" : "NO", fb ? "yes" : "NO");

        printf("== NullMoth driver: sysctls ==\n");
        sysctl_int("debug.nvaccel_headless");   // 1 = NVIDIA GPU is an app-only Metal device; WindowServer is elsewhere
        sysctl_int("debug.nmhybrid");           // hybrid level in effect (nmhybrid boot-arg)
        sysctl_str("debug.nmintelfb_step");     // last step the Intel panel provider reached
        sysctl_int("debug.nmhybrid_frames");
        sysctl_int("debug.nmhybrid_flips");
        sysctl_int("debug.nvaccel_iop_ok_h4");
        sysctl_str("debug.nmintelfb_dmc_want");

        printf("== Boot configuration ==\n");
        io_registry_entry_t opts = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/options");
        if (opts != IO_OBJECT_NULL) {
            NSString *ba = nvo_ioreg_prop_desc(opts, CFSTR("boot-args"));
            printf("  boot-args: %s\n", ba.UTF8String ?: "(unset)");
            if (ba) {
                printf("    nvaccel=1: %s  nvfb=1: %s  nmhybrid: %s  -nvoff: %s\n",
                       [ba containsString:@"nvaccel=1"] ? "yes" : "no", [ba containsString:@"nvfb=1"] ? "yes" : "no",
                       [ba containsString:@"nmhybrid="] ? "set" : "absent", [ba containsString:@"-nvoff"] ? "PRESENT (driver off)" : "absent");
            }
            NSString *csr = nvo_ioreg_prop_desc(opts, CFSTR("csr-active-config"));
            printf("  csr-active-config (NVRAM): %s\n", csr.UTF8String ?: "(unset)");
            IOObjectRelease(opts);
        }
        uint32_t csr = 0;
        if (csr_get_active_config(&csr) == 0) {
            printf("  SIP active config: 0x%08x  (NullMoth tested value 0x0a43; bit 0x1 off = kext signing, bit 0x4 off... )\n", csr);
            printf("    library validation / DYLD_INSERT_LIBRARIES into third-party apps: %s\n",
                   (csr & 0x1) ? "allowed (CSR_ALLOW_UNTRUSTED_KEXTS set, AMFI relaxed by boot-args)" : "may be blocked for hardened apps");
        }

        printf("== Environment: NullMoth / MoltenVK variables currently set ==\n");
        int set = 0;
        for (const char *const *v = kNullMothEnvVars; *v; v++) { const char *e = getenv(*v); if (e) { printf("  %s=%s\n", *v, e); set++; } }
        const char *mvk = getenv(MVK_ENV_FORCE_LOW_POWER);
        if (mvk) { printf("  %s=%s\n", MVK_ENV_FORCE_LOW_POWER, mvk); set++; }
        if (!set) printf("  (none)\n");
    }
}
