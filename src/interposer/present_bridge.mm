#import "interposer/present_bridge.h"
#import "interposer/device_select.h"
#import "interposer/policy.h"
#import <QuartzCore/CAMetalLayer.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#include "common/nvo_log.h"
#include "common/nvo_env.h"
#include <atomic>
#include <cstdlib>

static BOOL gTrace = NO;
static BOOL gBridgeEnabled = YES;
static id<MTLCommandQueue> gPresentQueue = nil;   // on the presenting device
static id<MTLCommandQueue> gSyncQueue = nil;      // on the render device, for synchronizeResource
static std::atomic<bool> gInstalled{false};

// ------------------------------------------------------------------ pixel formats we can share via IOSurface
static BOOL iosurface_format_for(MTLPixelFormat f, uint32_t *fourcc, size_t *bpe) {
    switch (f) {
        case MTLPixelFormatBGRA8Unorm:
        case MTLPixelFormatBGRA8Unorm_sRGB: *fourcc = 'BGRA'; *bpe = 4; return YES;
        case MTLPixelFormatRGBA16Float:     *fourcc = 'RGhA'; *bpe = 8; return YES;
        case MTLPixelFormatRGB10A2Unorm:    *fourcc = 'l10r'; *bpe = 4; return YES;
        default: return NO;
    }
}

// ------------------------------------------------------------------ per-layer state
@interface NVOLayerState : NSObject
@property(nonatomic) BOOL bridged;                       // layer actually sits on the present device
@property(nonatomic, strong) id<MTLDevice> wantedDevice; // what the app asked for (render device)
@property(nonatomic) NSUInteger frames;
@property(nonatomic, strong) NSMutableArray *ring;       // NVOSharedTarget, 3 deep
@end
@implementation NVOLayerState
@end

@interface NVOSharedTarget : NSObject
@property(nonatomic) IOSurfaceRef surface;
@property(nonatomic, strong) id<MTLTexture> renderTex;   // on the render device
@property(nonatomic, strong) id<MTLTexture> presentTex;  // on the present device
@property(nonatomic) NSUInteger width, height;
@property(nonatomic) MTLPixelFormat format;
@property(nonatomic) BOOL inFlight;
@end
@implementation NVOSharedTarget
- (void)dealloc { if (_surface) CFRelease(_surface); }
@end

static const void *kStateKey = &kStateKey;
static NVOLayerState *state_for(CAMetalLayer *layer) {
    NVOLayerState *s = objc_getAssociatedObject(layer, kStateKey);
    if (!s) { s = [NVOLayerState new]; s.ring = [NSMutableArray array]; objc_setAssociatedObject(layer, kStateKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return s;
}

static NVOSharedTarget *acquire_target(CAMetalLayer *layer, NVOLayerState *st) {
    CGSize ds = layer.drawableSize;
    NSUInteger w = (NSUInteger)ds.width, h = (NSUInteger)ds.height;
    MTLPixelFormat fmt = layer.pixelFormat;
    for (NVOSharedTarget *t in st.ring)
        if (!t.inFlight && t.width == w && t.height == h && t.format == fmt) { t.inFlight = YES; return t; }
    // Drop stale sizes.
    NSMutableArray *keep = [NSMutableArray array];
    for (NVOSharedTarget *t in st.ring) if (t.inFlight || (t.width == w && t.height == h && t.format == fmt)) [keep addObject:t];
    st.ring = keep;
    if (st.ring.count >= 3) return nil;   // 3 in flight: app is ahead of us, let it stall

    uint32_t fourcc = 0; size_t bpe = 0;
    if (!iosurface_format_for(fmt, &fourcc, &bpe)) return nil;
    NSDictionary *props = @{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h),
                             (id)kIOSurfaceBytesPerElement: @(bpe), (id)kIOSurfacePixelFormat: @(fourcc) };
    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!surf) { NVO_WARN("IOSurfaceCreate %lux%lu failed", (unsigned long)w, (unsigned long)h); return nil; }

    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    d.storageMode = MTLStorageModeManaged;   // IOSurface textures on x86 macOS: managed; GPU writes need synchronizeResource
    NVOSharedTarget *t = [NVOSharedTarget new];
    t.surface = surf; t.width = w; t.height = h; t.format = fmt; t.inFlight = YES;
    t.renderTex  = [nvo_render_device()  newTextureWithDescriptor:d iosurface:surf plane:0];
    t.presentTex = [nvo_present_device() newTextureWithDescriptor:d iosurface:surf plane:0];
    if (!t.renderTex || !t.presentTex) { NVO_WARN("newTextureWithDescriptor:iosurface: failed (render=%p present=%p)", t.renderTex, t.presentTex); return nil; }
    t.renderTex.label = @"nvoffload shared target (render)";
    t.presentTex.label = @"nvoffload shared target (present)";
    [st.ring addObject:t];
    NVO_INFO("bridge: new shared target %lux%lu fmt=%lu (ring %lu)", (unsigned long)w, (unsigned long)h, (unsigned long)fmt, (unsigned long)st.ring.count);
    return t;
}

// ------------------------------------------------------------------ proxy drawable handed to the app
@interface NVOProxyDrawable : NSObject <CAMetalDrawable>
@property(nonatomic, strong) id<CAMetalDrawable> real;      // on the present device
@property(nonatomic, strong) NVOSharedTarget *target;
@property(nonatomic, weak) CAMetalLayer *ownerLayer;
@property(nonatomic, strong) NSMutableArray<MTLDrawablePresentedHandler> *handlers;
@property(nonatomic) CFTimeInterval presentedTimeValue;
@property(nonatomic) BOOL finished;
- (void)nvo_finishPresentAtTime:(CFTimeInterval)t minimumDuration:(CFTimeInterval)dur;
@end

@implementation NVOProxyDrawable
- (id<MTLTexture>)texture { return self.target.renderTex; }
- (CAMetalLayer *)layer { return self.ownerLayer; }
- (NSUInteger)drawableID { return self.real.drawableID; }
- (CFTimeInterval)presentedTime { return self.presentedTimeValue; }
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)block {
    if (!self.handlers) self.handlers = [NSMutableArray array];
    [self.handlers addObject:[block copy]];
}
// Called directly by an app that presents the drawable itself instead of through the command buffer.
// We cannot know which command buffer rendered into it, so this path is unsynchronized.
- (void)present { NVO_WARN("bridge: -[drawable present] called directly; frame may be torn (use presentDrawable:)"); [self nvo_finishPresentAtTime:0 minimumDuration:0]; }
- (void)presentAtTime:(CFTimeInterval)t { [self nvo_finishPresentAtTime:t minimumDuration:0]; }
- (void)presentAfterMinimumDuration:(CFTimeInterval)d { [self nvo_finishPresentAtTime:0 minimumDuration:d]; }

- (void)nvo_finishPresentAtTime:(CFTimeInterval)t minimumDuration:(CFTimeInterval)dur {
    if (self.finished) return;
    self.finished = YES;
    NVOSharedTarget *tg = self.target;
    id<CAMetalDrawable> real = self.real;
    // 1. render device: push the managed texture's GPU copy out to the IOSurface pages.
    id<MTLCommandBuffer> sync = [gSyncQueue commandBuffer];
    sync.label = @"nvoffload sync";
    id<MTLBlitCommandEncoder> sb = [sync blitCommandEncoder];
    [sb synchronizeResource:tg.renderTex];
    [sb endEncoding];
    NSArray *handlers = self.handlers;
    [sync addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        if (cb.error) NVO_WARN("bridge: sync command buffer failed: %s", cb.error.localizedDescription.UTF8String);
        // 2. present device: blit the IOSurface into the real drawable and present it.
        id<MTLCommandBuffer> pcb = [gPresentQueue commandBuffer];
        pcb.label = @"nvoffload present";
        id<MTLBlitCommandEncoder> b = [pcb blitCommandEncoder];
        [b copyFromTexture:tg.presentTex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                sourceSize:MTLSizeMake(tg.width, tg.height, 1)
                 toTexture:real.texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [b endEncoding];
        for (MTLDrawablePresentedHandler h in handlers) [real addPresentedHandler:h];
        if (t > 0) [pcb presentDrawable:real atTime:t];
        else if (dur > 0) [pcb presentDrawable:real afterMinimumDuration:dur];
        else [pcb presentDrawable:real];
        [pcb addCompletedHandler:^(id<MTLCommandBuffer> c2) {
            if (c2.error) NVO_WARN("bridge: present command buffer failed: %s", c2.error.localizedDescription.UTF8String);
            self.presentedTimeValue = real.presentedTime;
            tg.inFlight = NO;
        }];
        [pcb commit];
    }];
    [sync commit];
}
@end

// ------------------------------------------------------------------ CAMetalLayer swizzles
static IMP orig_setDevice, orig_device, orig_nextDrawable, orig_preferredDevice;

static void nvo_setDevice(CAMetalLayer *self, SEL _cmd, id<MTLDevice> dev) {
    NVOLayerState *st = state_for(self);
    id<MTLDevice> render = nvo_render_device(), present = nvo_present_device();
    if (gBridgeEnabled && render && present && dev && dev.registryID == render.registryID) {
        st.bridged = YES; st.wantedDevice = dev;
        self.framebufferOnly = NO;   // the real drawable is a blit destination
        NVO_INFO("bridge: layer %p asked for %s; placing it on %s and bridging", self, dev.name.UTF8String, present.name.UTF8String);
        ((void (*)(id, SEL, id))orig_setDevice)(self, _cmd, present);
        return;
    }
    st.bridged = NO; st.wantedDevice = nil;
    if (gTrace) NVO_INFO("layer %p device = %s (pass-through)", self, dev ? dev.name.UTF8String : "nil");
    ((void (*)(id, SEL, id))orig_setDevice)(self, _cmd, dev);
}

static id<MTLDevice> nvo_device(CAMetalLayer *self, SEL _cmd) {
    NVOLayerState *st = objc_getAssociatedObject(self, kStateKey);
    if (st.bridged && st.wantedDevice) return st.wantedDevice;
    return ((id (*)(id, SEL))orig_device)(self, _cmd);
}

static id<MTLDevice> nvo_preferredDevice(CAMetalLayer *self, SEL _cmd) {
    id<MTLDevice> r = nvo_render_device();
    if (r) return r;   // apps that honour preferredDevice should still land on the NVIDIA GPU
    return ((id (*)(id, SEL))orig_preferredDevice)(self, _cmd);
}

static id<CAMetalDrawable> nvo_nextDrawable(CAMetalLayer *self, SEL _cmd) {
    NVOLayerState *st = state_for(self);
    id<CAMetalDrawable> real = ((id (*)(id, SEL))orig_nextDrawable)(self, _cmd);
    st.frames++;
    if (gTrace && (st.frames == 1 || st.frames % 300 == 0)) {
        id<MTLTexture> tex = real.texture;
        NVO_INFO("layer %p frame %lu: device=%s fmt=%lu size=%.0fx%.0f fbOnly=%d displaySync=%d iosurface=%p bridged=%d",
                 self, (unsigned long)st.frames, self.device.name.UTF8String, (unsigned long)self.pixelFormat,
                 self.drawableSize.width, self.drawableSize.height, self.framebufferOnly, self.displaySyncEnabled,
                 (void *)tex.iosurface, st.bridged);
    }
    if (!st.bridged || !real) return real;
    NVOSharedTarget *tg = acquire_target(self, st);
    if (!tg) { NVO_WARN("bridge: no shared target for layer %p; handing out the native drawable this frame", self); return real; }
    NVOProxyDrawable *p = [NVOProxyDrawable new];
    p.real = real; p.target = tg; p.ownerLayer = self;
    return p;
}

// ------------------------------------------------------------------ MTLCommandBuffer presentDrawable: swizzles (render device class)
static IMP orig_present, orig_presentAt, orig_presentAfter;
static void nvo_cb_presentDrawable(id self, SEL _cmd, id<MTLDrawable> d) {
    if ([d isKindOfClass:[NVOProxyDrawable class]]) {
        NVOProxyDrawable *p = (NVOProxyDrawable *)d;
        [self addCompletedHandler:^(id<MTLCommandBuffer> cb) { [p nvo_finishPresentAtTime:0 minimumDuration:0]; }];
        return;
    }
    ((void (*)(id, SEL, id))orig_present)(self, _cmd, d);
}
static void nvo_cb_presentDrawableAtTime(id self, SEL _cmd, id<MTLDrawable> d, CFTimeInterval t) {
    if ([d isKindOfClass:[NVOProxyDrawable class]]) {
        NVOProxyDrawable *p = (NVOProxyDrawable *)d;
        [self addCompletedHandler:^(id<MTLCommandBuffer> cb) { [p nvo_finishPresentAtTime:t minimumDuration:0]; }];
        return;
    }
    ((void (*)(id, SEL, id, CFTimeInterval))orig_presentAt)(self, _cmd, d, t);
}
static void nvo_cb_presentDrawableAfter(id self, SEL _cmd, id<MTLDrawable> d, CFTimeInterval dur) {
    if ([d isKindOfClass:[NVOProxyDrawable class]]) {
        NVOProxyDrawable *p = (NVOProxyDrawable *)d;
        [self addCompletedHandler:^(id<MTLCommandBuffer> cb) { [p nvo_finishPresentAtTime:0 minimumDuration:dur]; }];
        return;
    }
    ((void (*)(id, SEL, id, CFTimeInterval))orig_presentAfter)(self, _cmd, d, dur);
}

static IMP swizzle(Class c, SEL sel, IMP repl) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { NVO_WARN("swizzle: %s has no %s", class_getName(c), sel_getName(sel)); return nullptr; }
    IMP orig = method_getImplementation(m);
    // If the method is inherited, add an override on c so the superclass keeps its own implementation.
    if (!class_addMethod(c, sel, repl, method_getTypeEncoding(m))) method_setImplementation(m, repl);
    return orig;
}

void nvo_bridge_install_if_needed(void) {
    if (!nvo_policy_active()) return;
    bool expected = false;
    if (!gInstalled.compare_exchange_strong(expected, true)) return;
    const char *t = getenv(NVO_ENV_TRACE_PRESENT); gTrace = t && atoi(t) != 0;
    const char *b = getenv(NVO_ENV_BRIDGE);        gBridgeEnabled = !(b && atoi(b) == 0);

    Class layerClass = NSClassFromString(@"CAMetalLayer");
    if (!layerClass) { NVO_INFO("CAMetalLayer not loaded in this process; bridge idle"); gInstalled = false; return; }

    id<MTLDevice> render = nvo_render_device(), present = nvo_present_device();
    if (gBridgeEnabled && render && present) {
        gSyncQueue = [render newCommandQueue];  gSyncQueue.label = @"nvoffload sync queue";
        gPresentQueue = [present newCommandQueue]; gPresentQueue.label = @"nvoffload present queue";
        // Discover the render device's concrete command buffer class and hook its present methods.
        id<MTLCommandBuffer> probe = [gSyncQueue commandBuffer];
        Class cbClass = [probe class];
        orig_present      = swizzle(cbClass, @selector(presentDrawable:), (IMP)nvo_cb_presentDrawable);
        orig_presentAt    = swizzle(cbClass, @selector(presentDrawable:atTime:), (IMP)nvo_cb_presentDrawableAtTime);
        orig_presentAfter = swizzle(cbClass, @selector(presentDrawable:afterMinimumDuration:), (IMP)nvo_cb_presentDrawableAfter);
        NVO_INFO("bridge: active. render=%s present=%s cmdbuf class=%s", render.name.UTF8String, present.name.UTF8String, class_getName(cbClass));
    } else {
        NVO_INFO("bridge: inactive (%s); layers pass through%s",
                 !gBridgeEnabled ? "disabled by env" : !render ? "no render device" : "no presenting Metal device",
                 gTrace ? ", tracing presents" : "");
    }
    orig_setDevice       = swizzle(layerClass, @selector(setDevice:), (IMP)nvo_setDevice);
    orig_device          = swizzle(layerClass, @selector(device), (IMP)nvo_device);
    orig_nextDrawable    = swizzle(layerClass, @selector(nextDrawable), (IMP)nvo_nextDrawable);
    orig_preferredDevice = swizzle(layerClass, @selector(preferredDevice), (IMP)nvo_preferredDevice);
}
