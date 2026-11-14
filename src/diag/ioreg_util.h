#pragma once
#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>

// Small IORegistry helpers shared by the diagnostics.
NSString *nvo_ioreg_class(io_registry_entry_t e);                 // IOObjectGetClass
NSString *nvo_ioreg_name(io_registry_entry_t e);                  // IORegistryEntryGetName
NSString *nvo_ioreg_path(io_registry_entry_t e);                  // IOService plane path
NSString *nvo_ioreg_prop_desc(io_registry_entry_t e, CFStringRef key); // property rendered as text, or nil
BOOL      nvo_ioreg_prop_u32(io_registry_entry_t e, CFStringRef key, uint32_t *out); // 4-byte data or number
io_registry_entry_t nvo_ioreg_ancestor_of_class(io_registry_entry_t e, const char *cls); // retained, or IO_OBJECT_NULL
NSString *nvo_ioreg_pci_ids(io_registry_entry_t pciDev);          // "10de:25a0 class 030200" from an IOPCIDevice
io_registry_entry_t nvo_ioreg_from_registry_id(uint64_t rid);     // retained, or IO_OBJECT_NULL
