#pragma once
#import <Metal/Metal.h>

// Device policy shared by the interposed Metal entry points and the present bridge.
// render  = the GPU apps should render on (NVIDIA via NullMoth); nil means "do not override".
// present = the GPU that owns the display *if it is a Metal device* (Intel iGPU on <= 10th gen);
//           nil on machines like Tiger Lake where the panel sits on a firmware framebuffer.
void          nvo_devices_ensure(void);
id<MTLDevice> nvo_render_device(void);
id<MTLDevice> nvo_present_device(void);
