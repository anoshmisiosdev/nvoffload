#import "diag/ioreg_util.h"

NSString *nvo_ioreg_class(io_registry_entry_t e) {
    io_name_t n = {0};
    if (IOObjectGetClass(e, n) != KERN_SUCCESS) return @"?";
    return [NSString stringWithUTF8String:n];
}

NSString *nvo_ioreg_name(io_registry_entry_t e) {
    io_name_t n = {0};
    if (IORegistryEntryGetName(e, n) != KERN_SUCCESS) return @"?";
    return [NSString stringWithUTF8String:n];
}

NSString *nvo_ioreg_path(io_registry_entry_t e) {
    io_string_t p = {0};
    if (IORegistryEntryGetPath(e, kIOServicePlane, p) != KERN_SUCCESS) return @"?";
    return [NSString stringWithUTF8String:p];
}

static NSString *describe_cf(CFTypeRef v) {
    if (!v) return nil;
    CFTypeID t = CFGetTypeID(v);
    if (t == CFStringGetTypeID()) return (__bridge NSString *)v;
    if (t == CFNumberGetTypeID()) return [NSString stringWithFormat:@"%@", (__bridge NSNumber *)v];
    if (t == CFBooleanGetTypeID()) return CFBooleanGetValue((CFBooleanRef)v) ? @"true" : @"false";
    if (t == CFDataGetTypeID()) {
        NSData *d = (__bridge NSData *)v;
        if (d.length == 4) {
            uint32_t u; memcpy(&u, d.bytes, 4);
            return [NSString stringWithFormat:@"0x%08x", u];
        }
        if (d.length <= 32) {
            NSMutableString *s = [NSMutableString stringWithString:@"<"];
            const uint8_t *b = (const uint8_t *)d.bytes;
            for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", b[i]];
            [s appendString:@">"];
            return s;
        }
        return [NSString stringWithFormat:@"<%lu bytes>", (unsigned long)d.length];
    }
    if (t == CFArrayGetTypeID() || t == CFDictionaryGetTypeID())
        return [NSString stringWithFormat:@"%@", (__bridge id)v];
    return @"(unprintable)";
}

NSString *nvo_ioreg_prop_desc(io_registry_entry_t e, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, key, kCFAllocatorDefault, 0);
    if (!v) return nil;
    NSString *s = describe_cf(v);
    CFRelease(v);
    return s;
}

BOOL nvo_ioreg_prop_u32(io_registry_entry_t e, CFStringRef key, uint32_t *out) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, key, kCFAllocatorDefault, 0);
    if (!v) return NO;
    BOOL ok = NO;
    if (CFGetTypeID(v) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)v) >= 4) {
        memcpy(out, CFDataGetBytePtr((CFDataRef)v), 4);
        ok = YES;
    } else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        int64_t n = 0;
        CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &n);
        *out = (uint32_t)n;
        ok = YES;
    }
    CFRelease(v);
    return ok;
}

io_registry_entry_t nvo_ioreg_ancestor_of_class(io_registry_entry_t e, const char *cls) {
    io_registry_entry_t cur = e;
    IOObjectRetain(cur);
    while (cur != IO_OBJECT_NULL) {
        if (IOObjectConformsTo(cur, cls)) return cur;
        io_registry_entry_t parent = IO_OBJECT_NULL;
        kern_return_t kr = IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent);
        IOObjectRelease(cur);
        if (kr != KERN_SUCCESS) return IO_OBJECT_NULL;
        cur = parent;
    }
    return IO_OBJECT_NULL;
}

NSString *nvo_ioreg_pci_ids(io_registry_entry_t pci) {
    uint32_t ven = 0, dev = 0, cc = 0, sub = 0;
    nvo_ioreg_prop_u32(pci, CFSTR("vendor-id"), &ven);
    nvo_ioreg_prop_u32(pci, CFSTR("device-id"), &dev);
    nvo_ioreg_prop_u32(pci, CFSTR("class-code"), &cc);
    nvo_ioreg_prop_u32(pci, CFSTR("subsystem-id"), &sub);
    return [NSString stringWithFormat:@"%04x:%04x class %06x subsys %04x", ven & 0xffff, dev & 0xffff, cc & 0xffffff, sub & 0xffff];
}

io_registry_entry_t nvo_ioreg_from_registry_id(uint64_t rid) {
    CFMutableDictionaryRef m = IORegistryEntryIDMatching(rid);
    if (!m) return IO_OBJECT_NULL;
    return IOServiceGetMatchingService(kIOMainPortDefault, m); // consumes m
}
