#import "diag/nvo_diag.h"
#import "diag/ioreg_util.h"
#import <IOKit/graphics/IOGraphicsLib.h>
#include <cstdio>

// Print the driver classes attached below a registry entry, up to `depth` levels.
static void print_children(io_registry_entry_t e, int depth, int indent) {
    if (depth == 0) return;
    io_iterator_t it = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildIterator(e, kIOServicePlane, &it) != KERN_SUCCESS) return;
    io_registry_entry_t c;
    while ((c = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        NSString *cls = nvo_ioreg_class(c);
        const char *tag = IOObjectConformsTo(c, "IOFramebuffer") ? " [IOFramebuffer]"
                        : IOObjectConformsTo(c, "IOAccelerator") ? " [IOAccelerator]"
                        : IOObjectConformsTo(c, "IODisplay")     ? " [IODisplay]" : "";
        printf("%*s%s%s\n", indent, "", cls.UTF8String, tag);
        print_children(c, depth - 1, indent + 2);
        IOObjectRelease(c);
    }
    IOObjectRelease(it);
}

void nvo_print_pci_display_devices(void) {
    @autoreleasepool {
        printf("== PCI display-class devices (class 03xxxx) ==\n");
        io_iterator_t it = IO_OBJECT_NULL;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPCIDevice"), &it) != KERN_SUCCESS) {
            printf("  IOPCIDevice enumeration failed\n"); return;
        }
        io_registry_entry_t e; int n = 0;
        while ((e = IOIteratorNext(it)) != IO_OBJECT_NULL) {
            uint32_t cc = 0;
            if (nvo_ioreg_prop_u32(e, CFSTR("class-code"), &cc) && ((cc >> 16) & 0xff) == 0x03) {
                n++;
                const char *kind = ((cc >> 8) & 0xff) == 0x02 ? "3D controller (no scan-out: headless/Optimus dGPU)"
                                 : ((cc >> 8) & 0xff) == 0x00 ? "VGA/display controller (can own a panel)" : "other display class";
                printf("  %s  %s\n", nvo_ioreg_name(e).UTF8String, nvo_ioreg_pci_ids(e).UTF8String);
                printf("    kind: %s\n", kind);
                printf("    path: %s\n", nvo_ioreg_path(e).UTF8String);
                NSString *model = nvo_ioreg_prop_desc(e, CFSTR("model"));
                NSString *aapl  = nvo_ioreg_prop_desc(e, CFSTR("AAPL,ig-platform-id"));
                NSString *dis   = nvo_ioreg_prop_desc(e, CFSTR("disable-gpu"));
                if (model) printf("    model: %s\n", model.UTF8String);
                if (aapl)  printf("    AAPL,ig-platform-id: %s\n", aapl.UTF8String);
                if (dis)   printf("    disable-gpu: %s\n", dis.UTF8String);
                printf("    attached drivers:\n");
                print_children(e, 4, 6);
            }
            IOObjectRelease(e);
        }
        IOObjectRelease(it);
        if (!n) printf("  (none found)\n");
    }
}

void nvo_print_framebuffers(void) {
    @autoreleasepool {
        printf("== IOFramebuffers (who owns each display head) ==\n");
        io_iterator_t it = IO_OBJECT_NULL;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &it) != KERN_SUCCESS) {
            printf("  enumeration failed\n"); return;
        }
        io_registry_entry_t e; int n = 0;
        while ((e = IOIteratorNext(it)) != IO_OBJECT_NULL) {
            n++;
            NSString *cls = nvo_ioreg_class(e);
            const char *note =
                [cls containsString:@"IONDRVFramebuffer"] ? "firmware/UEFI GOP framebuffer: no GPU driver, CPU-drawn desktop" :
                [cls hasPrefix:@"NMIntelFB"]              ? "NullMoth Intel panel provider (nmhybrid path)" :
                [cls hasPrefix:@"NMGopFB"]                ? "NullMoth GOP panel provider (nmhybrid path)" :
                [cls containsString:@"NVRM"]              ? "NullMoth NVIDIA framebuffer" :
                [cls containsString:@"AppleIntel"]        ? "Apple Intel framebuffer (accelerated iGPU)" : "";
            printf("  %s  %s\n", cls.UTF8String, note);
            printf("    path: %s\n", nvo_ioreg_path(e).UTF8String);
            io_registry_entry_t pci = nvo_ioreg_ancestor_of_class(e, "IOPCIDevice");
            if (pci != IO_OBJECT_NULL) { printf("    pci: %s %s\n", nvo_ioreg_name(pci).UTF8String, nvo_ioreg_pci_ids(pci).UTF8String); IOObjectRelease(pci); }
            const CFStringRef keys[] = { CFSTR("IOFBDependentID"), CFSTR("IOFBDependentIndex"), CFSTR("IOFramebufferOpenGLIndex"),
                                         CFSTR("IOFBCurrentPixelClock"), CFSTR("IOFBTransform"), CFSTR("IOFBConfig"), CFSTR("IOAccelIndex") };
            for (auto k : keys) { NSString *v = nvo_ioreg_prop_desc(e, k); if (v) printf("    %s=%s\n", [(__bridge NSString *)k UTF8String], v.UTF8String); }
            // IODisplayConnect -> IODisplay children carry the panel identity.
            io_iterator_t cit = IO_OBJECT_NULL;
            if (IORegistryEntryCreateIterator(e, kIOServicePlane, kIORegistryIterateRecursively, &cit) == KERN_SUCCESS) {
                io_registry_entry_t c;
                while ((c = IOIteratorNext(cit)) != IO_OBJECT_NULL) {
                    if (IOObjectConformsTo(c, "IODisplay")) {
                        CFDictionaryRef info = IODisplayCreateInfoDictionary(c, kIODisplayOnlyPreferredName);
                        NSDictionary *d = CFBridgingRelease(info);
                        NSDictionary *names = d[@"DisplayProductName"];
                        printf("    display: %s vendor=%s product=%s builtin=%s edid=%s\n",
                               nvo_ioreg_class(c).UTF8String,
                               [(d[@"DisplayVendorID"] ?: @"-") description].UTF8String,
                               [(d[@"DisplayProductID"] ?: @"-") description].UTF8String,
                               [(d[@"built-in"] ?: @"-") description].UTF8String, d[@"IODisplayEDID"] ? "yes" : "no");
                        if (names.count) printf("    display name: %s\n", [[names.allValues firstObject] UTF8String]);
                    }
                    IOObjectRelease(c);
                }
                IOObjectRelease(cit);
            }
            IOObjectRelease(e);
        }
        IOObjectRelease(it);
        if (!n) printf("  (none: WindowServer is on a virtual display, see NullMoth issue 119)\n");
    }
}

void nvo_print_accelerators(void) {
    @autoreleasepool {
        printf("== IOAccelerators (Metal plugins) ==\n");
        io_iterator_t it = IO_OBJECT_NULL;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) {
            printf("  enumeration failed\n"); return;
        }
        io_registry_entry_t e; int n = 0;
        while ((e = IOIteratorNext(it)) != IO_OBJECT_NULL) {
            n++;
            uint64_t rid = 0; IORegistryEntryGetRegistryEntryID(e, &rid);
            printf("  %s registryID=0x%llx\n", nvo_ioreg_class(e).UTF8String, rid);
            printf("    path: %s\n", nvo_ioreg_path(e).UTF8String);
            io_registry_entry_t pci = nvo_ioreg_ancestor_of_class(e, "IOPCIDevice");
            if (pci != IO_OBJECT_NULL) { printf("    pci: %s %s\n", nvo_ioreg_name(pci).UTF8String, nvo_ioreg_pci_ids(pci).UTF8String); IOObjectRelease(pci); }
            const CFStringRef keys[] = { CFSTR("MetalPluginName"), CFSTR("MetalPluginClassName"), CFSTR("IOGLBundleName"),
                                         CFSTR("IOAccelRevision"), CFSTR("IOAccelIndex"), CFSTR("IOAccelTypes"), CFSTR("CFBundleIdentifier") };
            for (auto k : keys) { NSString *v = nvo_ioreg_prop_desc(e, k); if (v) printf("    %s=%s\n", [(__bridge NSString *)k UTF8String], v.UTF8String); }
            IOObjectRelease(e);
        }
        IOObjectRelease(it);
        if (!n) printf("  (none)\n");
    }
}
