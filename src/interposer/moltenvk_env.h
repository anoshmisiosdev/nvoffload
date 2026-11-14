#pragma once
// MoltenVK enumerates VkPhysicalDevices from MTLCopyAllDevices() and puts MTLCreateSystemDefaultDevice()
// first unless MVK_CONFIG_FORCE_LOW_POWER_GPU=1. Both calls are interposed, so forcing that variable to 0
// is all that is needed for physicalDevices[0] to be the NVIDIA GPU. Must run before MoltenVK's
// vkCreateInstance, i.e. from the dylib constructor.
void nvo_moltenvk_env_setup(void);
