#import <Foundation/Foundation.h>
#import "interposer/device_select.h"
#import "interposer/moltenvk_env.h"
#import "interposer/present_bridge.h"
#import "interposer/policy.h"
#include "common/nvo_log.h"
#include <unistd.h>

// Runs when DYLD_INSERT_LIBRARIES loads us, before the app's main(). Keep it cheap: no Metal device
// creation here (that happens lazily on the app's first Metal call), only environment and hooks.
__attribute__((constructor)) static void nvo_init(void) {
    NVO_INFO("libnvoffload loaded into pid %d (%s)", getpid(), [[NSProcessInfo processInfo] processName].UTF8String);
    if (!nvo_policy_active()) { NVO_INFO("inactive here: %s", nvo_policy_reason()); return; }
    nvo_moltenvk_env_setup();
    nvo_bridge_install_if_needed();   // no-op if QuartzCore is not linked yet; retried on first Metal call
}
