// nvoffload-presenter: the smallest possible "render on GPU A, show on the panel" experiment.
//
//   --cpu            fill the IOSurface from the CPU (proves IOSurface -> CALayer.contents works on this desktop)
//   --device=<name>  render into the IOSurface with Metal on the named device (default: NVIDIA-looking, else default)
//   --surface=<id>   do not render; display an existing global IOSurface by ID (from another process)
//   --size=WxH       surface size (default 1280x720)
//
// It opens a window whose backing CALayer has the IOSurface as its contents. WindowServer samples the
// surface directly, which is the lowest-copy path available from user space. On a machine whose panel is
// on a firmware framebuffer this tells us whether NullMoth writes frames back to the IOSurface's host pages
// in a form WindowServer's software compositor can show.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#include "common/nvo_log.h"
#include <cstdio>
#include <cstring>
#include <cmath>

@interface NVOPresenter : NSObject <NSApplicationDelegate>
@property(nonatomic) IOSurfaceRef surface;
@property(nonatomic) NSUInteger width, height;
@property(nonatomic) BOOL cpuMode;
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) CALayer *surfaceLayer;
@property(nonatomic) NSUInteger frame;
@property(nonatomic) CFTimeInterval lastReport;
@property(nonatomic) NSUInteger framesAtReport;
@end

@implementation NVOPresenter

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSRect r = NSMakeRect(100, 100, self.width / 2.0, self.height / 2.0);
    self.window = [[NSWindow alloc] initWithContentRect:r
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.title = [NSString stringWithFormat:@"nvoffload-presenter: %s", self.cpuMode ? "CPU fill" : self.device.name.UTF8String];
    NSView *v = self.window.contentView;
    v.wantsLayer = YES;
    self.surfaceLayer = [CALayer layer];
    self.surfaceLayer.frame = v.bounds;
    self.surfaceLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    self.surfaceLayer.contentsGravity = kCAGravityResizeAspect;
    self.surfaceLayer.contents = (__bridge id)self.surface;
    [v.layer addSublayer:self.surfaceLayer];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    if (!self.cpuMode && self.device) {
        self.queue = [self.device newCommandQueue];
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:self.width height:self.height mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeManaged;
        self.texture = [self.device newTextureWithDescriptor:d iosurface:self.surface plane:0];
        if (!self.texture) { fprintf(stderr, "newTextureWithDescriptor:iosurface: failed on %s\n", self.device.name.UTF8String); exit(1); }
    }
    self.lastReport = CACurrentMediaTime();
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)fillCPU {
    IOSurfaceLock(self.surface, 0, NULL);
    uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(self.surface);
    size_t pitch = IOSurfaceGetBytesPerRow(self.surface);
    float t = (float)(self.frame % 240) / 240.0f;
    for (NSUInteger y = 0; y < self.height; y++) {
        uint32_t *row = (uint32_t *)(base + y * pitch);
        for (NSUInteger x = 0; x < self.width; x++) {
            uint8_t rch = (uint8_t)(255.0f * (float)x / self.width), g = (uint8_t)(255.0f * (float)y / self.height), b = (uint8_t)(255.0f * t);
            bool bar = ((x + (NSUInteger)(t * self.width)) % self.width) < 40;
            row[x] = bar ? 0xffffffffu : (0xff000000u | (rch << 16) | (g << 8) | b);
        }
    }
    IOSurfaceUnlock(self.surface, 0, NULL);
}

- (void)renderGPU {
    float t = (float)(self.frame % 240) / 240.0f;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = self.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.5 + 0.5 * sin(t * 6.283), 0.5 + 0.5 * sin(t * 6.283 + 2.1), 0.5 + 0.5 * sin(t * 6.283 + 4.2), 1);
    id<MTLCommandBuffer> cb = [self.queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc endEncoding];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit synchronizeResource:self.texture];   // managed texture: make the GPU's pixels visible in the IOSurface pages
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.error) fprintf(stderr, "frame %lu: %s\n", (unsigned long)self.frame, cb.error.localizedDescription.UTF8String);
}

- (void)tick {
    if (self.cpuMode) [self fillCPU];
    else if (self.device) [self renderGPU];
    // Tell Core Animation the surface changed. setContentsChanged is the cheap private path; reassigning works everywhere.
    if ([self.surfaceLayer respondsToSelector:NSSelectorFromString(@"setContentsChanged")])
        [self.surfaceLayer performSelector:NSSelectorFromString(@"setContentsChanged")];
    else { self.surfaceLayer.contents = nil; self.surfaceLayer.contents = (__bridge id)self.surface; }
    self.frame++;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastReport >= 2.0) {
        printf("frame %lu, %.1f fps, IOSurface id %u (%lux%lu)\n", (unsigned long)self.frame,
               (double)(self.frame - self.framesAtReport) / (now - self.lastReport),
               IOSurfaceGetID(self.surface), (unsigned long)self.width, (unsigned long)self.height);
        self.lastReport = now; self.framesAtReport = self.frame;
    }
}
@end

static id<MTLDevice> pick_device(const char *name) {
    NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
    if (name && *name) for (id<MTLDevice> d in all) if ([d.name rangeOfString:@(name) options:NSCaseInsensitiveSearch].location != NSNotFound) return d;
    for (id<MTLDevice> d in all) for (NSString *k in @[@"NVIDIA", @"GeForce", @"RTX", @"GTX"]) if ([d.name containsString:k]) return d;
    return MTLCreateSystemDefaultDevice();
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *devName = nullptr; bool cpu = false; uint32_t surfId = 0; NSUInteger w = 1280, h = 720;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--cpu")) cpu = true;
            else if (!strncmp(argv[i], "--device=", 9)) devName = argv[i] + 9;
            else if (!strncmp(argv[i], "--surface=", 10)) surfId = (uint32_t)strtoul(argv[i] + 10, nullptr, 0);
            else if (!strncmp(argv[i], "--size=", 7)) { unsigned a = 0, b = 0; if (sscanf(argv[i] + 7, "%ux%u", &a, &b) == 2) { w = a; h = b; } }
            else { fprintf(stderr, "usage: %s [--cpu | --device=<name> | --surface=<id>] [--size=WxH]\n", argv[0]); return 2; }
        }
        NVOPresenter *p = [NVOPresenter new];
        p.cpuMode = cpu;
        if (surfId) {
            p.surface = IOSurfaceLookup(surfId);
            if (!p.surface) { fprintf(stderr, "IOSurfaceLookup(%u) failed (surface must be global)\n", surfId); return 1; }
            p.width = IOSurfaceGetWidth(p.surface); p.height = IOSurfaceGetHeight(p.surface);
            p.cpuMode = YES; p.device = nil;    // display only; tick() will just mark it changed
        } else {
            NSDictionary *props = @{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4,
                                     (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'), (id)kIOSurfaceIsGlobal: @YES };
            p.surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
            if (!p.surface) { fprintf(stderr, "IOSurfaceCreate failed\n"); return 1; }
            p.width = w; p.height = h;
            if (!cpu) { p.device = pick_device(devName); if (!p.device) { fprintf(stderr, "no Metal device\n"); return 1; } }
        }
        printf("presenter: %s, IOSurface id %u, %lux%lu\n", p.cpuMode ? "CPU fill / display-only" : p.device.name.UTF8String,
               IOSurfaceGetID(p.surface), (unsigned long)p.width, (unsigned long)p.height);
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        app.delegate = p;
        [app run];
    }
    return 0;
}
