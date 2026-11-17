#import "NVOAppDelegate.h"
#import <UserNotifications/UserNotifications.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <IOKit/IOKitLib.h>
#include "common/nvo_env.h"

// Policy file shared with libnvoffload (see src/interposer/policy.h for the schema).
static NSString *const kModeOff = @"off", *const kModeAllow = @"allowlist", *const kModeAll = @"all";
static NSString *const kDefaultsStartAtLogin = @"StartAtLogin";
static NSString *const kDefaultsSuggest = @"SuggestHeavyApps";

@interface NVOAppDelegate () <UNUserNotificationCenterDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMutableDictionary *policy;
@property(nonatomic, strong) NSTimer *gpuTimer;
@property(nonatomic, strong) NSMenuItem *loadItem;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *busySince;   // bundle id -> time Intel load went high
@property(nonatomic, strong) NSMutableSet<NSString *> *suggested;
@property(nonatomic) BOOL nullmothPresent;
@end

@implementation NVOAppDelegate

// ---------------------------------------------------------------- paths
- (NSString *)supportDir {
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"nvoffload"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
- (NSString *)policyPath { return [[self supportDir] stringByAppendingPathComponent:@"policy.json"]; }
- (NSString *)bundledPath:(NSString *)name {   // libnvoffload.dylib and nvprime-run travel inside Contents/MacOS
    return [[[NSBundle mainBundle].executablePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:name];
}

// ---------------------------------------------------------------- policy
- (void)loadPolicy {
    NSData *d = [NSData dataWithContentsOfFile:[self policyPath]];
    id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    self.policy = [obj isKindOfClass:[NSDictionary class]] ? [obj mutableCopy] : [@{@"mode": kModeAllow, @"apps": @[], @"exclude": @[]} mutableCopy];
    if (![self.policy[@"apps"] isKindOfClass:[NSMutableArray class]]) self.policy[@"apps"] = [NSMutableArray arrayWithArray:self.policy[@"apps"] ?: @[]];
    if (![self.policy[@"exclude"] isKindOfClass:[NSMutableArray class]]) self.policy[@"exclude"] = [NSMutableArray arrayWithArray:self.policy[@"exclude"] ?: @[]];
}
- (void)savePolicy {
    NSData *d = [NSJSONSerialization dataWithJSONObject:self.policy options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToFile:[self policyPath] atomically:YES];
    [self applyEnvironment];
    [self rebuildMenu];
}
- (NSString *)mode { return self.policy[@"mode"] ?: kModeOff; }

// ---------------------------------------------------------------- session environment (what makes new apps pick up the dylib)
- (void)launchctl:(NSArray<NSString *> *)args {
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"]; t.arguments = args;
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice]; t.standardError = t.standardOutput;
    [t launchAndReturnError:nil]; [t waitUntilExit];
}
- (void)applyEnvironment {
    NSString *dylib = [self bundledPath:@"libnvoffload.dylib"];
    if ([[self mode] isEqualToString:kModeOff]) {
        [self launchctl:@[@"unsetenv", @"DYLD_INSERT_LIBRARIES"]];
        [self launchctl:@[@"unsetenv", @(NVO_ENV_POLICY)]];
    } else {
        [self launchctl:@[@"setenv", @(NVO_ENV_POLICY), [self policyPath]]];
        [self launchctl:@[@"setenv", @(NVO_ENV_DEVICE), @"nvidia"]];
        [self launchctl:@[@"setenv", @(MVK_ENV_FORCE_LOW_POWER), @"0"]];
        [self launchctl:@[@"setenv", @"DYLD_INSERT_LIBRARIES", dylib]];
    }
}

// ---------------------------------------------------------------- GPU utilization (IOAccelerator PerformanceStatistics)
// Returns {"Intel": %, "NVIDIA": %} for whatever accelerators publish a utilization key.
- (NSDictionary<NSString *, NSNumber *> *)gpuLoads {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) return out;
    io_registry_entry_t e;
    while ((e = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        io_name_t cls = {0}; IOObjectGetClass(e, cls);
        NSString *name = [@(cls) containsString:@"NV"] ? @"NVIDIA" : @"Intel";
        if ([@(cls) hasPrefix:@"NVAccel"]) self.nullmothPresent = YES;
        CFTypeRef stats = IORegistryEntryCreateCFProperty(e, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
        if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
            NSDictionary *s = (__bridge NSDictionary *)stats;
            for (NSString *key in @[@"Device Utilization %", @"GPU Activity(%)", @"GPU Core Utilization", @"Renderer Utilization %"]) {
                if ([s[key] isKindOfClass:[NSNumber class]]) { out[name] = s[key]; break; }
            }
        }
        if (stats) CFRelease(stats);
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
    return out;
}

// ---------------------------------------------------------------- heavy-app detection
// A non-Apple frontmost app keeping the Intel GPU above 60% for 8 s while the NVIDIA GPU is idle gets a one-time
// suggestion to be offloaded. Nothing is changed without the user accepting the notification.
- (void)tick {
    NSDictionary *loads = [self gpuLoads];
    NSNumber *intel = loads[@"Intel"], *nv = loads[@"NVIDIA"];
    self.loadItem.title = [NSString stringWithFormat:@"GPU load:  Intel %@%%  ·  NVIDIA %@%%",
                           intel ? [NSString stringWithFormat:@"%d", intel.intValue] : @"–",
                           nv ? [NSString stringWithFormat:@"%d", nv.intValue] : (self.nullmothPresent ? @"?" : @"absent")];
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kDefaultsSuggest]) return;
    NSRunningApplication *front = [NSWorkspace sharedWorkspace].frontmostApplication;
    NSString *bid = front.bundleIdentifier;
    if (!bid || [bid hasPrefix:@"com.apple."] || [bid hasPrefix:@"org.nvoffload."]) return;
    if ([self.policy[@"apps"] containsObject:bid] || [self.suggested containsObject:bid]) return;
    BOOL heavy = intel && intel.intValue >= 60 && (!nv || nv.intValue < 10);
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!heavy) { [self.busySince removeObjectForKey:bid]; return; }
    if (!self.busySince[bid]) { self.busySince[bid] = @(now); return; }
    if (now - self.busySince[bid].doubleValue < 8) return;
    [self.suggested addObject:bid];
    [self suggestApp:front];
}
- (void)suggestApp:(NSRunningApplication *)app {
    UNMutableNotificationContent *c = [UNMutableNotificationContent new];
    c.title = @"Run on the NVIDIA GPU?";
    c.body = [NSString stringWithFormat:@"%@ is working the Intel GPU hard. Add it to the offload list so it uses the RTX next time it launches.", app.localizedName];
    c.categoryIdentifier = @"nvo.suggest"; c.userInfo = @{@"bundle": app.bundleIdentifier ?: @""};
    UNNotificationRequest *r = [UNNotificationRequest requestWithIdentifier:[NSString stringWithFormat:@"nvo.%@", app.bundleIdentifier] content:c trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:r withCompletionHandler:nil];
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)(void))completionHandler {
    NSString *bid = response.notification.request.content.userInfo[@"bundle"];
    if ([response.actionIdentifier isEqualToString:@"nvo.add"] || [response.actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier]) {
        if (bid.length && ![self.policy[@"apps"] containsObject:bid]) { [self.policy[@"apps"] addObject:bid]; [self savePolicy]; }
    }
    completionHandler();
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

// ---------------------------------------------------------------- menu
- (void)rebuildMenu {
    NSMenu *menu = [NSMenu new];
    NSMenuItem *hdr = [[NSMenuItem alloc] initWithTitle:self.nullmothPresent ? @"NVOffload — NullMoth GPU present" : @"NVOffload — NVIDIA GPU not found" action:nil keyEquivalent:@""];
    hdr.enabled = NO; [menu addItem:hdr];
    self.loadItem = [[NSMenuItem alloc] initWithTitle:@"GPU load:  …" action:nil keyEquivalent:@""]; self.loadItem.enabled = NO; [menu addItem:self.loadItem];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *modeHdr = [[NSMenuItem alloc] initWithTitle:@"Offload mode" action:nil keyEquivalent:@""]; modeHdr.enabled = NO; [menu addItem:modeHdr];
    for (NSArray *m in @[@[kModeOff, @"Off"], @[kModeAllow, @"Listed apps only"], @[kModeAll, @"All third-party apps"]]) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:m[1] action:@selector(setModeFromMenu:) keyEquivalent:@""];
        it.representedObject = m[0]; it.state = [[self mode] isEqualToString:m[0]] ? NSControlStateValueOn : NSControlStateValueOff; it.indentationLevel = 1; [menu addItem:it];
    }
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *appsHdr = [[NSMenuItem alloc] initWithTitle:@"Offloaded apps" action:nil keyEquivalent:@""]; appsHdr.enabled = NO; [menu addItem:appsHdr];
    for (NSString *bid in self.policy[@"apps"]) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:bid action:@selector(removeAppFromMenu:) keyEquivalent:@""];
        it.representedObject = bid; it.indentationLevel = 1; it.toolTip = @"Click to remove"; [menu addItem:it];
    }
    NSMenuItem *add = [[NSMenuItem alloc] initWithTitle:@"Add App…" action:@selector(addApp:) keyEquivalent:@""]; add.indentationLevel = 1; [menu addItem:add];
    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"Launch an App on the NVIDIA GPU…" action:@selector(launchOnce:) keyEquivalent:@""];
    NSMenuItem *sug = [menu addItemWithTitle:@"Suggest heavy apps (notifications)" action:@selector(toggleSuggest:) keyEquivalent:@""];
    sug.state = [[NSUserDefaults standardUserDefaults] boolForKey:kDefaultsSuggest] ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *login = [menu addItemWithTitle:@"Start at Login" action:@selector(toggleLogin:) keyEquivalent:@""];
    login.state = [[NSUserDefaults standardUserDefaults] boolForKey:kDefaultsStartAtLogin] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItemWithTitle:@"Show Policy File in Finder" action:@selector(revealPolicy:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit NVOffload" action:@selector(quit:) keyEquivalent:@"q"];
    for (NSMenuItem *it in menu.itemArray) if (it.action) it.target = self;
    self.statusItem.menu = menu;
    [self tick];
}
- (void)setModeFromMenu:(NSMenuItem *)it { self.policy[@"mode"] = it.representedObject; [self savePolicy]; }
- (void)removeAppFromMenu:(NSMenuItem *)it { [self.policy[@"apps"] removeObject:it.representedObject]; [self savePolicy]; }
- (void)addApp:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel]; p.allowedContentTypes = @[[UTType typeWithIdentifier:@"com.apple.application-bundle"]];
    p.directoryURL = [NSURL fileURLWithPath:@"/Applications"]; p.message = @"Choose an app to run on the NVIDIA GPU";
    [NSApp activateIgnoringOtherApps:YES];
    if ([p runModal] != NSModalResponseOK) return;
    NSString *bid = [NSBundle bundleWithURL:p.URL].bundleIdentifier ?: p.URL.lastPathComponent;
    if (![self.policy[@"apps"] containsObject:bid]) [self.policy[@"apps"] addObject:bid];
    if ([[self mode] isEqualToString:kModeOff]) self.policy[@"mode"] = kModeAllow;
    [self savePolicy];
}
- (void)launchOnce:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel]; p.allowedContentTypes = @[[UTType typeWithIdentifier:@"com.apple.application-bundle"]];
    p.directoryURL = [NSURL fileURLWithPath:@"/Applications"]; p.message = @"Launch this app once on the NVIDIA GPU";
    [NSApp activateIgnoringOtherApps:YES];
    if ([p runModal] != NSModalResponseOK) return;
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:[self bundledPath:@"nvprime-run"]];
    t.arguments = @[@"--log=1", p.URL.path];
    NSMutableDictionary *env = [[NSProcessInfo processInfo].environment mutableCopy]; [env removeObjectForKey:@(NVO_ENV_POLICY)]; t.environment = env;
    [t launchAndReturnError:nil];
}
- (void)toggleSuggest:(id)sender {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults]; [d setBool:![d boolForKey:kDefaultsSuggest] forKey:kDefaultsSuggest];
    if ([d boolForKey:kDefaultsSuggest]) [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound completionHandler:^(BOOL g, NSError *e) {}];
    [self rebuildMenu];
}
- (void)toggleLogin:(id)sender {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults]; BOOL on = ![d boolForKey:kDefaultsStartAtLogin]; [d setBool:on forKey:kDefaultsStartAtLogin];
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *plist = [dir stringByAppendingPathComponent:@"org.nvoffload.agent.plist"];
    if (on) {
        NSDictionary *la = @{@"Label": @"org.nvoffload.agent", @"ProgramArguments": @[[NSBundle mainBundle].executablePath], @"RunAtLoad": @YES, @"KeepAlive": @NO};
        [[NSPropertyListSerialization dataWithPropertyList:la format:NSPropertyListXMLFormat_v1_0 options:0 error:nil] writeToFile:plist atomically:YES];
    } else [[NSFileManager defaultManager] removeItemAtPath:plist error:nil];
    [self rebuildMenu];
}
- (void)revealPolicy:(id)sender { [[NSWorkspace sharedWorkspace] selectFile:[self policyPath] inFileViewerRootedAtPath:[self supportDir]]; }
- (void)quit:(id)sender { [NSApp terminate:nil]; }

// ---------------------------------------------------------------- lifecycle
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.busySince = [NSMutableDictionary dictionary]; self.suggested = [NSMutableSet set];
    [self loadPolicy];
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *img = [NSImage imageWithSystemSymbolName:@"gpu" accessibilityDescription:@"NVOffload"] ?: [NSImage imageWithSystemSymbolName:@"cpu" accessibilityDescription:@"NVOffload"];
    if (img) { [img setTemplate:YES]; self.statusItem.button.image = img; } else self.statusItem.button.title = @"NV";
    UNUserNotificationCenter *nc = [UNUserNotificationCenter currentNotificationCenter]; nc.delegate = self;
    UNNotificationAction *addAct = [UNNotificationAction actionWithIdentifier:@"nvo.add" title:@"Offload it" options:UNNotificationActionOptionNone];
    [nc setNotificationCategories:[NSSet setWithObject:[UNNotificationCategory categoryWithIdentifier:@"nvo.suggest" actions:@[addAct] intentIdentifiers:@[] options:0]]];
    [self gpuLoads];                 // sets nullmothPresent
    [self applyEnvironment];         // re-apply the session environment at every start (launchctl setenv does not persist)
    [self rebuildMenu];
    self.gpuTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}
- (void)applicationWillTerminate:(NSNotification *)n { /* leave the session environment as configured; Off clears it */ }
@end
