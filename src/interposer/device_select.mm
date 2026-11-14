#import "interposer/device_select.h"
#import "interposer/present_bridge.h"
#include "common/nvo_log.h"
#include "common/nvo_env.h"
#include <dispatch/dispatch.h>
#include <cstdlib>

static id<MTLDevice> g_render = nil;
static id<MTLDevice> g_present = nil;
static dispatch_once_t g_once;

static BOOL name_matches_any(NSString *n, NSArray<NSString *> *keys) {
    for (NSString *k in keys)
        if ([n rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}
static BOOL is_nvidia(id<MTLDevice> d) { return name_matches_any(d.name, @[@"NVIDIA", @"GeForce", @"RTX", @"GTX", @"Quadro", @"TITAN"]); }
static BOOL is_intel(id<MTLDevice> d)  { return name_matches_any(d.name, @[@"Intel"]); }

static void pick_devices(void) {
    @autoreleasepool {
        // Inside the interposing image these resolve to the real Metal functions (dyld does not
        // apply an image's own interpose tuples to itself).
        NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
        const char *prefC = getenv(NVO_ENV_DEVICE);
        NSString *pref = prefC && *prefC ? @(prefC) : @"nvidia";
        NVO_INFO("devices: %lu visible, policy \"%s\"", (unsigned long)all.count, pref.UTF8String);
        for (id<MTLDevice> d in all)
            NVO_INFO("  %s registryID=0x%llx lowPower=%d headless=%d", d.name.UTF8String, d.registryID, d.isLowPower, d.isHeadless);

        if ([pref isEqualToString:@"default"]) { NVO_INFO("device override disabled by policy"); return; }

        for (id<MTLDevice> d in all) {
            BOOL hit = NO;
            if ([pref isEqualToString:@"nvidia"])            hit = is_nvidia(d);
            else if ([pref isEqualToString:@"intel"])        hit = is_intel(d);
            else if ([pref hasPrefix:@"registry:"])          hit = (strtoull([pref substringFromIndex:9].UTF8String, nullptr, 0) == d.registryID);
            else                                             hit = name_matches_any(d.name, @[pref]);
            if (hit) { g_render = d; break; }
        }
        if (!g_render && [pref isEqualToString:@"nvidia"]) {
            // No NVIDIA-looking name (NullMoth may report the marketing name only). Fall back to the
            // first discrete, non-removable device.
            for (id<MTLDevice> d in all) if (!d.isLowPower && !d.isRemovable) { g_render = d; break; }
        }
        if (!g_render) { NVO_WARN("no device matched policy \"%s\"; leaving Metal defaults alone", pref.UTF8String); return; }

        // The presenting device: the low-power one that is not the render device. On a laptop whose
        // iGPU has no macOS driver (11th gen Intel and later) this stays nil and the bridge stays off.
        for (id<MTLDevice> d in all) if (d.isLowPower && d.registryID != g_render.registryID) { g_present = d; break; }
        if (!g_present) for (id<MTLDevice> d in all) if (!d.isHeadless && d.registryID != g_render.registryID) { g_present = d; break; }

        NVO_INFO("render device  : %s", g_render.name.UTF8String);
        NVO_INFO("present device : %s", g_present ? g_present.name.UTF8String : "(none: single-GPU Metal; panel on firmware framebuffer or same GPU)");
        if (all.count == 1)
            NVO_INFO("single Metal device: MTLCreateSystemDefaultDevice already returns it; nothing to redirect");
    }
}

void nvo_devices_ensure(void) { dispatch_once(&g_once, ^{ pick_devices(); }); }
id<MTLDevice> nvo_render_device(void)  { nvo_devices_ensure(); return g_render; }
id<MTLDevice> nvo_present_device(void) { nvo_devices_ensure(); return g_present; }

// ------------------------------------------------------------------ interposed entry points

#define DYLD_INTERPOSE(_replacement, _replacee)                                                     \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; }          \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {                       \
        (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

static NSArray<id<MTLDevice>> *render_first(NSArray<id<MTLDevice>> *all) {
    id<MTLDevice> r = nvo_render_device();
    if (!r || all.count < 2) return all;
    NSMutableArray<id<MTLDevice>> *m = [NSMutableArray arrayWithCapacity:all.count];
    for (id<MTLDevice> d in all) if (d.registryID == r.registryID) [m addObject:d];
    for (id<MTLDevice> d in all) if (d.registryID != r.registryID) [m addObject:d];
    return m;
}

extern "C" id<MTLDevice> nvo_MTLCreateSystemDefaultDevice(void) NS_RETURNS_RETAINED;
extern "C" id<MTLDevice> nvo_MTLCreateSystemDefaultDevice(void) {
    nvo_bridge_install_if_needed();
    id<MTLDevice> r = nvo_render_device();
    if (r) { NVO_TRACE("MTLCreateSystemDefaultDevice -> %s", r.name.UTF8String); return r; }
    return MTLCreateSystemDefaultDevice();
}

extern "C" NSArray<id<MTLDevice>> *nvo_MTLCopyAllDevices(void) NS_RETURNS_RETAINED;
extern "C" NSArray<id<MTLDevice>> *nvo_MTLCopyAllDevices(void) {
    nvo_bridge_install_if_needed();
    return render_first(MTLCopyAllDevices());
}

extern "C" NSArray<id<MTLDevice>> *nvo_MTLCopyAllDevicesWithObserver(id<NSObject> __autoreleasing _Nullable *_Nonnull observer,
                                                                     MTLDeviceNotificationHandler handler) NS_RETURNS_RETAINED;
extern "C" NSArray<id<MTLDevice>> *nvo_MTLCopyAllDevicesWithObserver(id<NSObject> __autoreleasing _Nullable *_Nonnull observer,
                                                                     MTLDeviceNotificationHandler handler) {
    nvo_bridge_install_if_needed();
    return render_first(MTLCopyAllDevicesWithObserver(observer, handler));
}

DYLD_INTERPOSE(nvo_MTLCreateSystemDefaultDevice, MTLCreateSystemDefaultDevice)
DYLD_INTERPOSE(nvo_MTLCopyAllDevices, MTLCopyAllDevices)
DYLD_INTERPOSE(nvo_MTLCopyAllDevicesWithObserver, MTLCopyAllDevicesWithObserver)
