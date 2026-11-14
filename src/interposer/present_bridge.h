#pragma once
// Cross-GPU presentation bridge.
//
// Two-device machines (Intel iGPU with an Apple driver + NullMoth NVIDIA):
//   CAMetalLayer stays on the presenting (Intel) device so WindowServer composites it natively.
//   nextDrawable hands the app a proxy drawable whose texture lives on the NVIDIA device, backed by
//   an IOSurface. When the app presents it, we wait for the NVIDIA command buffer to complete,
//   synchronize the managed texture, then blit the same IOSurface into the real drawable on the
//   presenting device and present that.
//
// Single-device machines (Tiger Lake and later: the panel is on a firmware framebuffer and the
//   NVIDIA GPU is the only Metal device): there is nothing to bridge to. The layer is left alone and,
//   with NVOFFLOAD_TRACE_PRESENT=1, every nextDrawable/present is logged so we can see what
//   WindowServer is handed.
void nvo_bridge_install_if_needed(void);
