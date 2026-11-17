#import <Cocoa/Cocoa.h>
#import "NVOAppDelegate.h"
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        NVOAppDelegate *delegate = [NVOAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
