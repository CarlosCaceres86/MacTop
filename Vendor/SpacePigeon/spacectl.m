// spacectl - small helper that lets SpacePigeon move windows between
// Spaces and switch Spaces instantly, with SIP fully enabled.
//
// The window-management calls are taken from yabai
// (https://github.com/asmvik/yabai), Copyright (c) 2019 Asmund Vikane,
// MIT License, and from ferry (https://github.com/softmaxe/ferry),
// Copyright (c) 2026 softmaxe, MIT License.
//
//   move:   SkyLight's bridged "move windows to managed space" operation
//           (works with SIP on since macOS 26.4).
// These are private macOS interfaces. A macOS update can break them; every
// command verifies its result and exits non-zero when it did not work, so the
// Lua side can fall back to the old behaviour.
//
// Exit codes: 0 ok, 1 failed, 2 bad usage, 3 not supported on this macOS.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SPACECTL_VERSION "1.3.0"

#define SPACE_TYPE_USER       0
#define SPACE_TYPE_FULLSCREEN 4

#define SKYLIGHT_PATH "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
#define BRIDGED_OPERATION_SYMBOL "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"
#define BRIDGED_MOVE_CLASS "SLSBridgedMoveWindowsToManagedSpaceOperation"

extern int SLSMainConnectionID(void);
extern CFArrayRef SLSCopyManagedDisplaySpaces(int cid);
extern int SLSSpaceGetType(int cid, uint64_t sid);
extern CFArrayRef SLSCopySpacesForWindows(int cid, int selector, CFArrayRef window_list);
extern CFStringRef SLSCopyManagedDisplayForSpace(int cid, uint64_t sid);
extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef display);
extern CGError SLSSpaceSetFrontPSN(int cid, uint64_t sid, ProcessSerialNumber psn);
extern CGError SLSGetWindowOwner(int cid, uint32_t wid, int *wcid);
extern CGError SLSGetConnectionPSN(int cid, ProcessSerialNumber *psn);

typedef int64_t (*bridged_operation_fn)(void *operation);

static int g_cid;

static void fail(int code, const char *fmt, ...) __attribute__((noreturn, format(printf, 2, 3)));
static void fail(int code, const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    fputs("spacectl: ", stderr);
    vfprintf(stderr, fmt, args);
    fputc('\n', stderr);
    va_end(args);
    exit(code);
}

static uint64_t now_ns(void)
{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static double elapsed_ms(uint64_t start_ns)
{
    return (now_ns() - start_ns) / 1e6;
}

static void sleep_ms(double ms)
{
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, ms / 1000.0, true);
}

// The window server ignores the bridged move from processes that have not
// loaded AppKit. Referencing an AppKit class keeps the framework linked and
// loaded even if the linker would otherwise drop it.
static void ensure_appkit_loaded(void)
{
    (void) [NSWorkspace class];
}

//
// Symbol lookup for functions that SkyLight does not export
// (yabai: misc/macho_dlsym.h, via ferry).
//

static struct mach_header_64 *macho_find_image_header(const char *target_name, intptr_t *slide)
{
    uint32_t image_count = _dyld_image_count();
    for (uint32_t i = 0; i < image_count; ++i) {
        const char *image_name = _dyld_get_image_name(i);
        if (image_name && strcmp(image_name, target_name) == 0) {
            *slide = _dyld_get_image_vmaddr_slide(i);
            return (struct mach_header_64 *) _dyld_get_image_header(i);
        }
    }
    return NULL;
}

static void *macho_find_symbol(const char *target_image, const char *target_symbol)
{
    intptr_t slide = 0;
    struct mach_header_64 *header = macho_find_image_header(target_image, &slide);
    if (!header) return NULL;

    struct segment_command_64 *linkedit = NULL;
    struct symtab_command *symtab = NULL;
    uint8_t *cursor = (uint8_t *) header + sizeof(struct mach_header_64);

    for (uint32_t i = 0; i < header->ncmds; ++i) {
        struct load_command *cmd = (struct load_command *) cursor;
        if (cmd->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *) cmd;
            if (strncmp(segment->segname, SEG_LINKEDIT, sizeof(segment->segname)) == 0) {
                linkedit = segment;
            }
        } else if (cmd->cmd == LC_SYMTAB) {
            symtab = (struct symtab_command *) cmd;
        }
        cursor += cmd->cmdsize;
    }

    if (!linkedit || !symtab) return NULL;

    uint8_t *linkedit_base = (uint8_t *) (linkedit->vmaddr - linkedit->fileoff + slide);
    const char *strings = (const char *) (linkedit_base + symtab->stroff);
    struct nlist_64 *symbols = (struct nlist_64 *) (linkedit_base + symtab->symoff);

    for (uint32_t i = 0; i < symtab->nsyms; ++i) {
        if (strcmp(strings + symbols[i].n_un.n_strx, target_symbol) == 0) {
            return (void *) (symbols[i].n_value + slide);
        }
    }

    return NULL;
}

static bridged_operation_fn find_bridged_perform(void)
{
    static bool looked = false;
    static bridged_operation_fn perform = NULL;
    if (!looked) {
        looked = true;
        if (objc_getClass(BRIDGED_MOVE_CLASS)) {
            perform = (bridged_operation_fn) macho_find_symbol(SKYLIGHT_PATH, BRIDGED_OPERATION_SYMBOL);
        }
    }
    return perform;
}

//
// Spaces.
//

static uint64_t cfnumber_u64(CFTypeRef value)
{
    uint64_t result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef) value, kCFNumberSInt64Type, &result);
    }
    return result;
}

static void cfstring_to_buf(CFStringRef string, char *buf, size_t size)
{
    buf[0] = '\0';
    if (string) CFStringGetCString(string, buf, (CFIndex) size, kCFStringEncodingUTF8);
}

// Returns the 0-based position of `sid` within its display's space list and
// the number of spaces on that display, or -1 when the space is unknown.
static int space_index_on_display(uint64_t sid, int *count_out)
{
    CFArrayRef displays = SLSCopyManagedDisplaySpaces(g_cid);
    if (!displays) return -1;

    int result = -1;
    for (CFIndex i = 0; i < CFArrayGetCount(displays) && result < 0; ++i) {
        CFDictionaryRef display = CFArrayGetValueAtIndex(displays, i);
        CFArrayRef spaces = CFDictionaryGetValue(display, CFSTR("Spaces"));
        if (!spaces) continue;

        CFIndex count = CFArrayGetCount(spaces);
        for (CFIndex j = 0; j < count; ++j) {
            CFDictionaryRef space = CFArrayGetValueAtIndex(spaces, j);
            if (cfnumber_u64(CFDictionaryGetValue(space, CFSTR("id64"))) == sid) {
                result = (int) j;
                if (count_out) *count_out = (int) count;
                break;
            }
        }
    }

    CFRelease(displays);
    return result;
}

static CFArrayRef window_id_array(uint32_t wid)
{
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    CFArrayRef array = CFArrayCreate(NULL, (const void **) &number, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);
    return array;
}

// Space ids the window is on (0x7 = all space types).
static int window_spaces(uint32_t wid, uint64_t *out, int max)
{
    CFArrayRef windows = window_id_array(wid);
    CFArrayRef spaces = SLSCopySpacesForWindows(g_cid, 0x7, windows);
    CFRelease(windows);
    if (!spaces) return 0;

    int n = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(spaces) && n < max; ++i) {
        out[n++] = cfnumber_u64(CFArrayGetValueAtIndex(spaces, i));
    }
    CFRelease(spaces);
    return n;
}

//
// Commands.
//

static int cmd_check(void)
{
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    bool move = find_bridged_perform() != NULL;
    printf("{\"version\":\"%s\",\"macos\":\"%ld.%ld.%ld\",\"move\":%s}\n",
           SPACECTL_VERSION, (long) v.majorVersion, (long) v.minorVersion, (long) v.patchVersion,
           move ? "true" : "false");
    return move ? 0 : 3;
}

// Never interpolate an untrusted dictionary string into JSON.
static void print_space_uuid(CFDictionaryRef space)
{
    CFTypeRef value = CFDictionaryGetValue(space, CFSTR("uuid"));
    CFUUIDRef uuid = NULL;
    if (value && CFGetTypeID(value) == CFUUIDGetTypeID()) {
        uuid = (CFUUIDRef) CFRetain(value);
    } else if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        NSString *raw = (__bridge NSString *) value;
        NSUUID *parsed = [[NSUUID alloc] initWithUUIDString:raw];
        if (parsed && [raw caseInsensitiveCompare:parsed.UUIDString] == NSOrderedSame)
            uuid = CFUUIDCreateFromString(kCFAllocatorDefault, (__bridge CFStringRef) parsed.UUIDString);
        [parsed release];
    }
    if (!uuid) { printf("null"); return; }
    CFStringRef canonical = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    char buffer[37];
    if (canonical && CFStringGetCString(canonical, buffer, sizeof(buffer), kCFStringEncodingASCII) &&
        strcmp(buffer, "00000000-0000-0000-0000-000000000000") != 0) {
        printf("\"%s\"", buffer);
    } else printf("null");
    if (canonical) CFRelease(canonical);
    CFRelease(uuid);
}

static int cmd_spaces(void)
{
    CFArrayRef displays = SLSCopyManagedDisplaySpaces(g_cid);
    if (!displays) fail(1, "could not read spaces");

    printf("[");
    for (CFIndex i = 0; i < CFArrayGetCount(displays); ++i) {
        CFDictionaryRef display = CFArrayGetValueAtIndex(displays, i);
        char uuid[128];
        CFStringRef display_id = CFDictionaryGetValue(display, CFSTR("Display Identifier"));
        cfstring_to_buf(display_id, uuid, sizeof(uuid));
        uint64_t current = display_id ? SLSManagedDisplayGetCurrentSpace(g_cid, display_id) : 0;

        printf("%s{\"display\":\"%s\",\"current\":%llu,\"spaces\":[", i ? "," : "", uuid, (unsigned long long) current);
        CFArrayRef spaces = CFDictionaryGetValue(display, CFSTR("Spaces"));
        CFIndex count = spaces ? CFArrayGetCount(spaces) : 0;
        for (CFIndex j = 0; j < count; ++j) {
            CFDictionaryRef space = CFArrayGetValueAtIndex(spaces, j);
            uint64_t sid = cfnumber_u64(CFDictionaryGetValue(space, CFSTR("id64")));
            printf("%s{\"id\":%llu,\"type\":%d,\"uuid\":", j ? "," : "", (unsigned long long) sid, SLSSpaceGetType(g_cid, sid));
            print_space_uuid(space);
            printf("}");
        }
        printf("]}");
    }
    printf("]\n");

    CFRelease(displays);
    return 0;
}

// Standard-looking windows on any Space, front to back, for one process or
// (pid 0) for all processes. Works for windows on inactive Spaces, where
// Accessibility often cannot see them.
static int cmd_windows(pid_t pid)
{
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) fail(1, "could not read window list");

    printf("[");
    int printed = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(list); ++i) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(list, i);
        int owner = 0, layer = -1;
        uint32_t wid = 0;
        CFNumberRef owner_ref = CFDictionaryGetValue(info, kCGWindowOwnerPID);
        CFNumberRef layer_ref = CFDictionaryGetValue(info, kCGWindowLayer);
        CFNumberRef wid_ref = CFDictionaryGetValue(info, kCGWindowNumber);
        if (!owner_ref || !layer_ref || !wid_ref) continue;
        CFNumberGetValue(owner_ref, kCFNumberIntType, &owner);
        CFNumberGetValue(layer_ref, kCFNumberIntType, &layer);
        CFNumberGetValue(wid_ref, kCFNumberSInt32Type, &wid);
        if ((pid && owner != pid) || layer != 0 || !wid) continue;

        CGRect bounds = CGRectZero;
        CFDictionaryRef bounds_ref = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!bounds_ref || !CGRectMakeWithDictionaryRepresentation(bounds_ref, &bounds)) continue;
        if (bounds.size.width <= 0 || bounds.size.height <= 0) continue;

        uint64_t spaces[16];
        int n = window_spaces(wid, spaces, 16);
        // Keep unverified memberships; the consumer reports them as pending.

        printf("%s{\"id\":%u,\"pid\":%d,\"spaces\":[", printed++ ? "," : "", wid, owner);
        for (int s = 0; s < n; ++s) {
            printf("%s%llu", s ? "," : "", (unsigned long long) spaces[s]);
        }
        printf("],\"fullscreen\":%s,\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d}",
               n > 0 && SLSSpaceGetType(g_cid, spaces[0]) == SPACE_TYPE_FULLSCREEN ? "true" : "false",
               (int) bounds.origin.x, (int) bounds.origin.y,
               (int) bounds.size.width, (int) bounds.size.height);
    }
    printf("]\n");

    CFRelease(list);
    return 0;
}

// Moves one window and waits until the window server reports it on the target.
// Returns 0 on success, 1 when it did not arrive, 3 when unsupported.
static int move_window(uint32_t wid, uint64_t sid, int timeout_ms, double *took_ms)
{
    bridged_operation_fn perform = find_bridged_perform();
    if (!perform) return 3;

    uint64_t membership[16];
    if (window_spaces(wid, membership, 16) == 1 && membership[0] == sid) {
        if (took_ms) *took_ms = 0;
        return 0;
    }

    int owner_cid = 0;
    ProcessSerialNumber psn = {0};
    bool have_psn = SLSGetWindowOwner(g_cid, wid, &owner_cid) == kCGErrorSuccess &&
                    SLSGetConnectionPSN(owner_cid, &psn) == kCGErrorSuccess;

    uint64_t start = now_ns();
    Class cls = objc_getClass(BRIDGED_MOVE_CLASS);
    CFArrayRef windows = window_id_array(wid);
    SEL sel = sel_registerName("initWithWindows:spaceID:");
    id operation = ((id (*)(id, SEL, id, uint64_t)) objc_msgSend)([cls alloc], sel, (id) windows, sid);
    perform(operation);
    [operation release];
    CFRelease(windows);

    if (have_psn) SLSSpaceSetFrontPSN(g_cid, sid, psn);

    // The operation is asynchronous: poll until the window server agrees.
    bool moved = false;
    while (!(moved = window_spaces(wid, membership, 16) == 1 && membership[0] == sid) && elapsed_ms(start) < timeout_ms) {
        sleep_ms(2);
    }

    if (took_ms) *took_ms = elapsed_ms(start);
    return moved ? 0 : 1;
}

static int cmd_move(uint32_t wid, uint64_t sid, int timeout_ms)
{
    int owner_cid = 0;
    if (SLSGetWindowOwner(g_cid, wid, &owner_cid) != kCGErrorSuccess) fail(1, "window %u not found", wid);
    if (space_index_on_display(sid, NULL) < 0) fail(1, "space %llu not found", (unsigned long long) sid);
    if (SLSSpaceGetType(g_cid, sid) != SPACE_TYPE_USER) fail(2, "destination is not an ordinary desktop");
    uint64_t membership[16];
    if (window_spaces(wid, membership, 16) != 1 || SLSSpaceGetType(g_cid, membership[0]) != SPACE_TYPE_USER)
        fail(1, "source window is not exclusively on an ordinary desktop");

    double took = 0;
    int result = move_window(wid, sid, timeout_ms, &took);
    if (result == 3) fail(3, "bridged move operation not available on this macOS");
    if (result != 0) fail(1, "window %u did not reach space %llu within %d ms", wid, (unsigned long long) sid, timeout_ms);

    printf("{\"moved\":true,\"window\":%u,\"space\":%llu,\"ms\":%.1f}\n", wid, (unsigned long long) sid, took);
    return 0;
}

static void usage(FILE *stream)
{
    fputs("usage: spacectl check|spaces|windows [pid]|move <window-id> <space-id> <timeout-ms> <pid> <launch-epoch>|version\n", stream);
}

static unsigned long long parse_u64(const char *text, const char *what)
{
    char *end = NULL;
    unsigned long long value = strtoull(text, &end, 10);
    if (!end || *end != '\0' || value == 0) fail(2, "invalid %s '%s'", what, text);
    return value;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        ensure_appkit_loaded();
        g_cid = SLSMainConnectionID();

        if (argc < 2) {
            usage(stderr);
            return 2;
        }

        const char *cmd = argv[1];
        if (strcmp(cmd, "check") == 0) return cmd_check();
        if (strcmp(cmd, "spaces") == 0) return cmd_spaces();
        if (strcmp(cmd, "version") == 0) { puts(SPACECTL_VERSION); return 0; }
        if (strcmp(cmd, "-h") == 0 || strcmp(cmd, "--help") == 0 || strcmp(cmd, "help") == 0) { usage(stdout); return 0; }

        if (strcmp(cmd, "windows") == 0 && argc == 2) {
            return cmd_windows(0);
        }
        if (strcmp(cmd, "windows") == 0 && argc == 3) {
            return cmd_windows((pid_t) parse_u64(argv[2], "pid"));
        }
        if (strcmp(cmd, "move") == 0 && argc == 7) {
            uint64_t parsed_wid = parse_u64(argv[2], "window id");
            uint64_t parsed_timeout = parse_u64(argv[4], "timeout");
            uint64_t parsed_pid = parse_u64(argv[5], "pid");
            if (parsed_wid > UINT32_MAX || parsed_pid > INT32_MAX || parsed_timeout > 5000) fail(2, "argument out of range");
            pid_t pid = (pid_t) parsed_pid;
            NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
            char *end = NULL;
            double expected_launch = strtod(argv[6], &end);
            if (!end || *end || !isfinite(expected_launch) || !app.launchDate || fabs(app.launchDate.timeIntervalSince1970 - expected_launch) > 0.001)
                fail(1, "application instance changed");
            CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, (uint32_t) parsed_wid);
            bool owned = false;
            for (NSDictionary *window in (NSArray *) info) {
                if ([window[(id) kCGWindowNumber] unsignedIntValue] == parsed_wid && [window[(id) kCGWindowOwnerPID] intValue] == pid) owned = true;
            }
            if (info) CFRelease(info);
            if (!owned) fail(1, "window identity changed");
            return cmd_move((uint32_t) parsed_wid, parse_u64(argv[3], "space id"), (int) parsed_timeout);
        }

        usage(stderr);
        return 2;
    }
}

