#import <Foundation/Foundation.h>
#include "interposer/policy.h"
#include "common/nvo_env.h"
#include "common/nvo_log.h"
#include <mach-o/dyld.h>
#include <dispatch/dispatch.h>

static bool g_active = true;
static char g_reason[200] = "no policy file: active";

static void evaluate(void) {
    const char *pp = getenv(NVO_ENV_POLICY);
    if (!pp || !*pp) return;
    @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:@(pp)];
        NSDictionary *pol = nil;
        if (data) { id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]; if ([obj isKindOfClass:[NSDictionary class]]) pol = obj; }
        NSString *mode = [pol[@"mode"] isKindOfClass:[NSString class]] ? pol[@"mode"] : @"off";
        NSArray *apps = [pol[@"apps"] isKindOfClass:[NSArray class]] ? pol[@"apps"] : @[];
        NSArray *excl = [pol[@"exclude"] isKindOfClass:[NSArray class]] ? pol[@"exclude"] : @[];
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
        char exe[4096]; uint32_t n = sizeof exe;
        NSString *exeName = (_NSGetExecutablePath(exe, &n) == 0) ? [[NSString stringWithUTF8String:exe] lastPathComponent] : @"";
        BOOL (^listed)(NSArray *) = ^BOOL(NSArray *l) {
            for (id x in l) if ([x isKindOfClass:[NSString class]] && ([x isEqualToString:bid] || [x isEqualToString:exeName])) return YES;
            return NO;
        };
        if ([bid hasPrefix:@"org.nvoffload."] || [exeName isEqualToString:@"nvprime-run"] || [exeName isEqualToString:@"nvoffload-presenter"]) {
            g_active = false; snprintf(g_reason, sizeof g_reason, "nvoffload's own process");
        } else if (listed(excl)) {
            g_active = false; snprintf(g_reason, sizeof g_reason, "excluded by policy");
        } else if ([mode isEqualToString:@"allowlist"]) {
            g_active = listed(apps); snprintf(g_reason, sizeof g_reason, g_active ? "allow-listed" : "not in allow-list");
        } else if ([mode isEqualToString:@"all"]) {
            g_active = listed(apps) || (bid.length > 0 && ![bid hasPrefix:@"com.apple."]);
            snprintf(g_reason, sizeof g_reason, g_active ? "mode all: third-party app" : "mode all: not a third-party GUI app");
        } else {
            g_active = false; snprintf(g_reason, sizeof g_reason, "mode off");
        }
        NVO_INFO("policy %s for %s (%s): %s", pp, bid.length ? bid.UTF8String : exeName.UTF8String, mode.UTF8String, g_reason);
    }
}

bool nvo_policy_active(void) {
    static dispatch_once_t once; dispatch_once(&once, ^{ evaluate(); });
    return g_active;
}
const char *nvo_policy_reason(void) { nvo_policy_active(); return g_reason; }
