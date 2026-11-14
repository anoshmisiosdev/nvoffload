#import "interposer/moltenvk_env.h"
#include "common/nvo_env.h"
#include "common/nvo_log.h"
#include <cstdlib>

void nvo_moltenvk_env_setup(void) {
    if (!getenv(MVK_ENV_FORCE_LOW_POWER)) {
        setenv(MVK_ENV_FORCE_LOW_POWER, "0", 0);
        NVO_INFO("MoltenVK: %s=0 (default device first)", MVK_ENV_FORCE_LOW_POWER);
    }
    // Vulkan apps that pick a physical device by VkPhysicalDeviceType or by vendorID (0x10de) need no
    // help; apps that hard-code index 0 are covered by the ordering above. A Vulkan implicit layer
    // (VK_LAYER_nvoffload_device_select) is the next step if an app enumerates and filters out the
    // headless device itself; see README "Vulkan".
}
