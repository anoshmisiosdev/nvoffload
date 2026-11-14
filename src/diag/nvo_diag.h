#pragma once
// Diagnostics printed by `nvprime-run --info`. Each function prints one section to stdout and
// never throws; a missing framework object is reported as a line, not an error.
#ifdef __cplusplus
extern "C" {
#endif
void nvo_print_metal_devices(void);      // MTLCopyAllDevices + MTLCreateSystemDefaultDevice, every identity flag
void nvo_print_pci_display_devices(void);// every PCI class-03 device and the drivers attached under it
void nvo_print_framebuffers(void);       // every IOFramebuffer (who owns the panel) and its IODisplay
void nvo_print_accelerators(void);       // every IOAccelerator and its Metal plugin name
void nvo_print_displays(void);           // CoreGraphics online displays
void nvo_print_nullmoth(void);           // bundles, kexts, sysctls, boot-args, SIP, env
#ifdef __cplusplus
}
#endif
