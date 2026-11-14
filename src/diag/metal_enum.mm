#import <Metal/Metal.h>
#import "diag/nvo_diag.h"
#import "diag/ioreg_util.h"
#include <cstdio>

static const char *loc_str(MTLDeviceLocation l) {
    switch (l) {
        case MTLDeviceLocationBuiltIn:    return "built-in";
        case MTLDeviceLocationSlot:       return "slot";
        case MTLDeviceLocationExternal:   return "external";
        case MTLDeviceLocationUnspecified:return "unspecified";
    }
    return "?";
}

static void print_registry_backing(id<MTLDevice> d) {
    io_registry_entry_t e = nvo_ioreg_from_registry_id(d.registryID);
    if (e == IO_OBJECT_NULL) { printf("      ioreg: registryID not found\n"); return; }
    printf("      ioreg: %s (%s)\n", nvo_ioreg_class(e).UTF8String, nvo_ioreg_path(e).UTF8String);
    NSString *plugin = nvo_ioreg_prop_desc(e, CFSTR("MetalPluginName"));
    NSString *glb    = nvo_ioreg_prop_desc(e, CFSTR("IOGLBundleName"));
    if (plugin || glb) printf("      MetalPluginName=%s IOGLBundleName=%s\n", plugin.UTF8String ?: "-", glb.UTF8String ?: "-");
    io_registry_entry_t pci = nvo_ioreg_ancestor_of_class(e, "IOPCIDevice");
    if (pci != IO_OBJECT_NULL) {
        printf("      pci: %s  %s\n", nvo_ioreg_name(pci).UTF8String, nvo_ioreg_pci_ids(pci).UTF8String);
        IOObjectRelease(pci);
    } else {
        printf("      pci: (no IOPCIDevice ancestor)\n");
    }
    IOObjectRelease(e);
}

void nvo_print_metal_devices(void) {
    @autoreleasepool {
        printf("== Metal devices ==\n");
        NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
        id<MTLDevice> def = MTLCreateSystemDefaultDevice();
        printf("MTLCopyAllDevices: %lu device(s); MTLCreateSystemDefaultDevice: %s\n",
               (unsigned long)all.count, def ? def.name.UTF8String : "nil");
        if (all.count == 0)
            printf("  (none) -> no Metal accelerator is registered; the desktop is software-composited\n");
        for (id<MTLDevice> d in all) {
            printf("  - %s\n", d.name.UTF8String);
            printf("      registryID=0x%llx lowPower=%d headless=%d removable=%d unifiedMemory=%d default=%s\n",
                   d.registryID, d.isLowPower, d.isHeadless, d.isRemovable, d.hasUnifiedMemory,
                   (def && def.registryID == d.registryID) ? "yes" : "no");
            printf("      location=%s#%lu peerGroupID=%llu peerIndex=%u peerCount=%u\n",
                   loc_str(d.location), (unsigned long)d.locationNumber, d.peerGroupID, d.peerIndex, d.peerCount);
            printf("      recommendedMaxWorkingSetSize=%llu MiB maxTransferRate=%llu B/s maxBufferLength=%lu MiB\n",
                   d.recommendedMaxWorkingSetSize >> 20, d.maxTransferRate, (unsigned long)(d.maxBufferLength >> 20));
            struct { MTLGPUFamily f; const char *n; } fams[] = {
                { MTLGPUFamilyMac2, "Mac2" }, { MTLGPUFamilyCommon3, "Common3" }, { MTLGPUFamilyMetal3, "Metal3" },
            };
            printf("      families:");
            for (auto &f : fams) if ([d supportsFamily:f.f]) printf(" %s", f.n);
            printf("  argbuf=tier%ld raytracing=%d 32bitMSAA=%d\n",
                   (long)d.argumentBuffersSupport + 1, d.supportsRaytracing, d.supports32BitMSAA);
            print_registry_backing(d);
        }
        if (def && all.count > 1) {
            printf("note: apps that call MTLCreateSystemDefaultDevice() get \"%s\"; nvoffload redirects that to the NVIDIA device.\n",
                   def.name.UTF8String);
        } else if (def && all.count == 1) {
            printf("note: single Metal device. Device selection is moot on this machine; presentation is the whole problem.\n");
        }
    }
}
