#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import "diag/nvo_diag.h"
#include <cstdio>

void nvo_print_displays(void) {
    @autoreleasepool {
        printf("== CoreGraphics displays ==\n");
        CGDirectDisplayID ids[16]; uint32_t n = 0;
        if (CGGetOnlineDisplayList(16, ids, &n) != kCGErrorSuccess) { printf("  CGGetOnlineDisplayList failed\n"); return; }
        if (!n) printf("  (none online)\n");
        for (uint32_t i = 0; i < n; i++) {
            CGDirectDisplayID d = ids[i];
            CGRect b = CGDisplayBounds(d);
            CGDisplayModeRef m = CGDisplayCopyDisplayMode(d);
            double hz = m ? CGDisplayModeGetRefreshRate(m) : 0;
            size_t pw = m ? CGDisplayModeGetPixelWidth(m) : 0, ph = m ? CGDisplayModeGetPixelHeight(m) : 0;
            CFArrayRef modes = CGDisplayCopyAllDisplayModes(d, NULL);
            printf("  display 0x%x%s%s: %.0fx%.0f pt (%zux%zu px) @ %.1f Hz, %ld modes, vendor=0x%x model=0x%x unit=%u active=%d\n",
                   d, CGDisplayIsMain(d) ? " [main]" : "", CGDisplayIsBuiltin(d) ? " [built-in]" : " [external?]",
                   b.size.width, b.size.height, pw, ph, hz, modes ? (long)CFArrayGetCount(modes) : -1L,
                   CGDisplayVendorNumber(d), CGDisplayModelNumber(d), CGDisplayUnitNumber(d), CGDisplayIsActive(d));
            if (hz == 0) printf("    refresh 0 Hz usually means a firmware framebuffer with no mode timing\n");
            if (modes && CFArrayGetCount(modes) <= 1) printf("    a single mode is the UEFI GOP framebuffer: no display driver owns this panel\n");
            if (m) CGDisplayModeRelease(m);
            if (modes) CFRelease(modes);
        }
    }
}
