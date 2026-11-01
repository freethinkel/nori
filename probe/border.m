// POC, not part of nori: a border around a window, drawn by Dock itself in a WALayerKitWindow. See docs/WINDOWSERVER.md.
// Goes into the running Dock with build/loader, so no Dock restart. One request per connection, one line back:
// /tmp/nori_border_$USER.socket, for example `echo "T 85" | nc -U /tmp/nori_border_$USER.socket`
//        "T wid"       border on that window
//        "C"           no border
//        "S"           state
//        "W 0|1"       follow the target's frame on a timer (default 1)
//        "D 0|1"       the timer reads the frame as drawn, window transforms included (default 1), or the real one
//        "G 0|1"       the next border window is the target's child, the way -addChildWindow:ordered: does it (default 0)
//        "o order rel" SLSTransactionOrderWindow on the border
//        "g order rel" SLSTransactionOrderWindowGroup on the border
//        "Y hex"       clears those tags on the border
//        "y hex"       sets those tags on the border
//        "I hex"       the tags the next border window is made with (default 200)
//        "O 0|1|4"     how a change is committed: SLSTransactionCommit(t, 0 or 1), or 4: with Core Animation's commit (default)
//        "E 0|1"       event shape: 1 empty, 0 the whole window
//        "J 0|1"       one second of what the payload would do, on the target (a test window): 0 a width stretch,
//                      1 a move, each frame with the border in one transaction
//        "Q"           tears this instance down
// An image stays in Dock for good, so a new instance first tells the one before it to quit.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
extern CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level);
extern CGError SLSSetWindowLevel(int cid, uint32_t wid, int level);
extern CGError SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);
extern CGError SLSSetWindowEventShape(int cid, uint32_t wid, CFTypeRef region);
extern CGError SLSClearWindowTags(int cid, uint32_t wid, const uint64_t *tags, int bits);
extern CGError SLSSetWindowTags(int cid, uint32_t wid, const uint64_t *tags, int bits);
extern CGError SLSGetWindowTags(int cid, uint32_t wid, uint64_t *tags, int bits);
extern CGError SLSTransactionOrderWindow(CFTypeRef transaction, uint32_t wid, int order, uint32_t rel_wid);
extern CGError SLSTransactionOrderWindowGroup(CFTypeRef transaction, uint32_t wid, int order, uint32_t rel_wid);
extern CGError SLSTransactionAddWindowToWindowMovementGroup(CFTypeRef transaction, uint32_t parent, uint32_t child);
extern CGError SLSTransactionAddWindowToWindowOrderingGroup(CFTypeRef transaction, uint32_t child, int order, uint32_t parent);
extern CFArrayRef SLSCopySpacesForWindows(int cid, int mask, CFArrayRef wids);
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef wids, uint64_t sid);
extern uint64_t SLSGetActiveSpace(int cid);
extern CFTypeRef SLSTransactionCreate(int cid);
extern CGError SLSTransactionCommit(CFTypeRef transaction, int synchronous);
extern CGError SLSTransactionCommitUsingMethod(CFTypeRef transaction, int method);
extern CGError SLSTransactionMoveWindowWithGroup(CFTypeRef transaction, uint32_t wid, CGPoint point);
extern CGError SLSTransactionSetWindowTransform3D(CFTypeRef transaction, uint32_t wid, const double *m);
extern CFTypeRef SLSWindowQueryWindows(int cid, CFArrayRef wids, int options);
extern CFTypeRef SLSWindowQueryResultCopyWindows(CFTypeRef query);
extern int SLSWindowIteratorGetCount(CFTypeRef iterator);
extern CFArrayRef SLSWindowIteratorGetCornerRadii(CFTypeRef iterator, long index);
extern CFTypeRef CGRegionCreateEmptyRegion(void);
extern CFTypeRef CGRegionCreateWithRect(CGRect rect);

#define BORDER_WIDTH 5.0
#define BORDER_GAP 1.5  // between the stroke and the window, as Mission Control's outline
#define BORDER_OUTSET (BORDER_WIDTH + BORDER_GAP)

static char socket_path[128];
static int cid;
static uint32_t target;
static id border;  // a WALayerKitWindow
static CALayer *ring;
static CGRect placed;
static double radius;
static bool watching = true, drawn = true, grouped;
static int commit_method = 4;
static uint64_t new_tags = 0x200;  // what ShowFrontWindowsController passes for its highlight window
static dispatch_source_t timer, animation;

static uint32_t border_wid(void)
{
    return border ? ((uint32_t (*)(id, SEL)) objc_msgSend)(border, sel_registerName("wid")) : 0;
}

static CFArrayRef number_array(uint32_t wid)
{
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    CFArrayRef array = CFArrayCreate(NULL, (const void **) &number, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);
    return array;
}

static float display_scale(CGDirectDisplayID display)
{
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (!mode) return 2;
    float scale = (float) CGDisplayModeGetPixelWidth(mode) / (float) CGDisplayModeGetWidth(mode);
    CGDisplayModeRelease(mode);
    return scale;
}

// WindowServer's radius of a window; its getter gives one value four times over.
static double corner_radius(uint32_t wid)
{
    double result = 0;
    CFArrayRef wids = number_array(wid);
    CFTypeRef query = SLSWindowQueryWindows(cid, wids, 0);
    CFTypeRef iterator = query ? SLSWindowQueryResultCopyWindows(query) : NULL;
    if (iterator && SLSWindowIteratorGetCount(iterator) > 0) {
        CFArrayRef radii = SLSWindowIteratorGetCornerRadii(iterator, 0);
        if (radii && CFArrayGetCount(radii) > 0) CFNumberGetValue(CFArrayGetValueAtIndex(radii, 0), kCFNumberDoubleType, &result);
        if (radii) CFRelease(radii);
    }
    if (iterator) CFRelease(iterator);
    if (query) CFRelease(query);
    CFRelease(wids);
    return result;
}

static void commit(CFTypeRef transaction)
{
    if (commit_method == 4) SLSTransactionCommitUsingMethod(transaction, 4);
    else SLSTransactionCommit(transaction, commit_method);
}

// The border to a frame, into a transaction that may carry the target's own change.
static void set_border(CGRect frame, CFTypeRef transaction)
{
    CGRect outer = CGRectInset(frame, -BORDER_OUTSET, -BORDER_OUTSET);
    ((void (*)(id, SEL, CGRect, CFTypeRef)) objc_msgSend)(border, sel_registerName("setFrame:with:"), outer, transaction);
    ring.frame = CGRectMake(0, 0, outer.size.width, outer.size.height);
    placed = frame;
}

static void place(CGRect frame)
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CFTypeRef transaction = SLSTransactionCreate(cid);
    set_border(frame, transaction);
    commit(transaction);
    CFRelease(transaction);
    [CATransaction commit];
    [CATransaction flush];
}

static void order_above_target(void)
{
    int level = 0;
    SLSGetWindowLevel(cid, target, &level);
    SLSSetWindowLevel(cid, border_wid(), level);
    SLSOrderWindow(cid, border_wid(), 1, target);
}

// A border window belongs on the one Space of its target, so it slides and scales with it.
static void join_target_space(void)
{
    CFArrayRef targets = number_array(target), own = number_array(border_wid());
    CFArrayRef spaces = SLSCopySpacesForWindows(cid, 7, targets);
    uint64_t sid = 0;
    if (spaces && CFArrayGetCount(spaces) > 0) CFNumberGetValue(CFArrayGetValueAtIndex(spaces, 0), kCFNumberSInt64Type, &sid);
    if (sid) SLSMoveWindowsToManagedSpace(cid, own, sid);
    CFRelease(own);
    CFRelease(targets);
    if (spaces) CFRelease(spaces);
}

// As -addChildWindow:ordered:, traced: the same three calls, child above parent.
static void adopt_border(void)
{
    uint32_t child = border_wid();
    CFTypeRef transaction = SLSTransactionCreate(cid);
    SLSTransactionAddWindowToWindowMovementGroup(transaction, target, child);
    SLSTransactionAddWindowToWindowOrderingGroup(transaction, child, 1, target);
    SLSTransactionOrderWindowGroup(transaction, child, 1, target);
    SLSTransactionCommit(transaction, 1);
    CFRelease(transaction);
}

static void clear_border(void)
{
    if (!border) return;
    SLSOrderWindow(cid, border_wid(), 0, 0);
    [ring removeFromSuperlayer];
    [ring release];
    [border release];
    ring = nil;
    border = nil;
    target = 0;
    [CATransaction flush];
}

static const char *make_border(CGRect frame)
{
    Class class = objc_getClass("WALayerKitWindow");
    SEL init = sel_registerName("initWithFrame:connection:display:scaleFactor:tags:level:");
    if (!class || !class_getInstanceMethod(class, init)) return "no WALayerKitWindow init";

    CGDirectDisplayID display = CGMainDisplayID();
    uint32_t count = 0;
    CGGetDisplaysWithRect(frame, 1, &display, &count);
    CGRect outer = CGRectInset(frame, -BORDER_OUTSET, -BORDER_OUTSET);
    border = ((id (*)(id, SEL, CGRect, uint32_t, uint32_t, float, uint64_t, int)) objc_msgSend)(
        ((id (*)(Class, SEL)) objc_msgSend)(class, sel_registerName("alloc")),
        init, outer, cid, display, display_scale(display), new_tags, 0);
    if (!border) return "init returned nil";

    CALayer *root = ((id (*)(id, SEL)) objc_msgSend)(border, sel_registerName("layer"));
    ring = [[CALayer alloc] init];
    CGColorRef color = CGColorCreateSRGB(0.188, 0.514, 0.984, 1);
    ring.borderColor = color;
    CGColorRelease(color);
    ring.borderWidth = BORDER_WIDTH;
    ring.cornerRadius = radius + BORDER_OUTSET;  // around the window's corner, so the stroke runs parallel to it
    ring.cornerCurve = kCACornerCurveContinuous;
    [root addSublayer:ring];

    CFTypeRef empty = CGRegionCreateEmptyRegion();
    SLSSetWindowEventShape(cid, border_wid(), empty);
    CFRelease(empty);
    return NULL;
}

// SLSGetWindowBounds leaves out window transforms, so nori's width stretch and its shifts past the screen edge.
// CGWindowList has them, and the Space's transform as well. Slides are vertical, so x and width are taken from it, the
// rest from the real frame; a Space that scales (the overview) changes the height, and then it isn't taken at all.
// ponytail: a guess from the frame alone. In the payload the stretch is known, nothing needs reading.
static CGRect drawn_frame(CGRect real)
{
    const void *wid = (const void *) (uintptr_t) target;
    CFArrayRef ids = CFArrayCreate(NULL, &wid, 1, NULL);
    CFArrayRef list = CGWindowListCreateDescriptionFromArray(ids);
    CFRelease(ids);
    CGRect result = real, bounds;
    if (list && CFArrayGetCount(list) > 0) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(list, 0);
        CFDictionaryRef dictionary = CFDictionaryGetValue(info, kCGWindowBounds);
        if (dictionary && CGRectMakeWithDictionaryRepresentation(dictionary, &bounds) && fabs(bounds.size.height - real.size.height) < 0.5) {
            result.origin.x = bounds.origin.x;
            result.size.width = bounds.size.width;
        }
    }
    if (list) CFRelease(list);
    return result;
}

static void tick(void)
{
    if (!border || !watching) return;
    CGRect frame;
    if (SLSGetWindowBounds(cid, target, &frame) != kCGErrorSuccess) {
        NSLog(@"nori-border: target %u gone", target);
        clear_border();
        return;
    }
    if (drawn) frame = drawn_frame(frame);
    if (!CGRectEqualToRect(frame, placed)) {
        place(frame);
        if (!grouped) order_above_target();
    }
}

static void put_border(uint32_t wid, char *reply, size_t size)
{
    CGRect frame;
    CGError error = SLSGetWindowBounds(cid, wid, &frame);
    if (error != kCGErrorSuccess) { snprintf(reply, size, "no window %u: %d", wid, error); return; }
    if (wid != target) clear_border();
    target = wid;
    radius = corner_radius(wid);
    bool created = !border;
    if (created) {
        const char *failed = make_border(frame);
        if (failed) { snprintf(reply, size, "%s", failed); target = 0; return; }
    }
    place(frame);
    join_target_space();
    order_above_target();
    if (created && grouped) adopt_border();
    [CATransaction flush];
    CGRect shown = CGRectNull;
    SLSGetWindowBounds(cid, border_wid(), &shown);
    snprintf(reply, size, "border %u on %u radius %.1f grouped %d at %.1f %.1f %.1f %.1f", border_wid(), wid, radius, grouped,
             shown.origin.x, shown.origin.y, shown.size.width, shown.size.height);
}

static void state(char *reply, size_t size)
{
    int level = 0;
    if (border) SLSGetWindowLevel(cid, border_wid(), &level);
    CGRect shown = CGRectNull;
    if (border) SLSGetWindowBounds(cid, border_wid(), &shown);
    uint64_t tags = 0;
    if (border) SLSGetWindowTags(cid, border_wid(), &tags, 64);
    snprintf(reply, size, "border %u target %u tags %llx radius %.1f level %d frame %.1f %.1f %.1f %.1f watching %d drawn %d grouped %d commit %d active-space %llu",
             border_wid(), target, tags, radius, level, shown.origin.x, shown.origin.y, shown.size.width, shown.size.height,
             watching, drawn, grouped, commit_method, SLSGetActiveSpace(cid));
}

// What the payload would do on every frame: the target's change and the border's in one transaction.
static void animate(int mode)
{
    if (!border || animation) return;
    CGRect start;
    if (SLSGetWindowBounds(cid, target, &start) != kCGErrorSuccess) return;
    bool was_watching = watching;
    watching = false;
    __block int frame = 0;
    animation = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(animation, DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(animation, ^{
        bool last = ++frame >= 60;
        double progress = last ? 0 : sin(M_PI * frame / 60);  // out and back
        CGRect now = start;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        CFTypeRef transaction = SLSTransactionCreate(cid);
        if (mode == 0) {
            double stretch = 1 + 0.5 * progress;
            double m[16] = { 1 / stretch, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1 };
            SLSTransactionSetWindowTransform3D(transaction, target, m);
            now.size.width = round(start.size.width * stretch);
        } else {
            now.origin.x = round(start.origin.x + 200 * progress);
            SLSTransactionMoveWindowWithGroup(transaction, target, now.origin);
        }
        set_border(now, transaction);
        commit(transaction);
        CFRelease(transaction);
        [CATransaction commit];
        [CATransaction flush];
        if (last) {
            dispatch_source_cancel(animation);
            dispatch_release(animation);
            animation = NULL;
            watching = was_watching;
        }
    });
    dispatch_resume(animation);
}

static void teardown(void)
{
    if (timer) dispatch_source_cancel(timer);
    timer = NULL;
    clear_border();
}

static void handle(char *line, char *reply, size_t size)
{
    snprintf(reply, size, "ok");
    @try {
        unsigned long value = strtoul(line + 1, NULL, 10);
        switch (line[0]) {
            case 'T': put_border((uint32_t) value, reply, size); break;
            case 'C': clear_border(); break;
            case 'S': state(reply, size); break;
            case 'W': watching = value != 0; break;
            case 'D': drawn = value != 0; break;
            case 'G': grouped = value != 0; break;
            case 'O': commit_method = (int) value; break;
            case 'J': animate((int) value); break;
            case 'I': new_tags = strtoull(line + 1, NULL, 16); break;
            case 'Y':
            case 'y': {
                uint64_t tags = strtoull(line + 1, NULL, 16);
                CGError error = line[0] == 'Y' ? SLSClearWindowTags(cid, border_wid(), &tags, 64) : SLSSetWindowTags(cid, border_wid(), &tags, 64);
                snprintf(reply, size, "tags: %d", error);
                break;
            }
            case 'o':
            case 'g': {
                int order;
                uint32_t rel;
                if (sscanf(line + 1, "%d %u", &order, &rel) != 2) { snprintf(reply, size, "order rel?"); break; }
                CFTypeRef transaction = SLSTransactionCreate(cid);
                if (line[0] == 'o') SLSTransactionOrderWindow(transaction, border_wid(), order, rel);
                else SLSTransactionOrderWindowGroup(transaction, border_wid(), order, rel);
                SLSTransactionCommit(transaction, 1);
                CFRelease(transaction);
                break;
            }
            case 'E': {
                CGRect outer = CGRectInset(placed, -BORDER_OUTSET, -BORDER_OUTSET);
                CFTypeRef region = value ? CGRegionCreateEmptyRegion() : CGRegionCreateWithRect(CGRectMake(0, 0, outer.size.width, outer.size.height));
                SLSSetWindowEventShape(cid, border_wid(), region);
                CFRelease(region);
                break;
            }
            default: snprintf(reply, size, "unknown line: %s", line);
        }
    } @catch (NSException *exception) {
        snprintf(reply, size, "exception: %s", exception.reason.UTF8String ?: "?");
    }
}

static void tell_previous_to_quit(void)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", socket_path);
    if (fd >= 0 && connect(fd, (struct sockaddr *) &addr, sizeof(addr)) == 0) {
        write(fd, "Q\n", 2);
        char buf[8];
        read(fd, buf, sizeof(buf));  // back once its window is gone
    }
    if (fd >= 0) close(fd);
}

static void reply_and_close(int client, const char *reply)
{
    write(client, reply, strlen(reply));
    write(client, "\n", 1);
    close(client);
}

static void *serve(void *unused)
{
    tell_previous_to_quit();
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", socket_path);
    unlink(socket_path);
    if (bind(server, (struct sockaddr *) &addr, sizeof(addr)) != 0 || listen(server, 4) != 0) {
        NSLog(@"nori-border: no socket");
        return NULL;
    }
    chmod(socket_path, 0600);
    dispatch_async(dispatch_get_main_queue(), ^{
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 8 * NSEC_PER_MSEC, NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{ tick(); });
        dispatch_resume(timer);
    });
    NSLog(@"nori-border: serving on %s, cid %d", socket_path, cid);
    for (;;) {
        int client = accept(server, NULL, NULL);
        if (client < 0) continue;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &(int){1}, sizeof(int));  // a client gone before its reply must not take Dock down
        char line[1024];
        ssize_t n = read(client, line, sizeof(line) - 1);
        if (n <= 0) { close(client); continue; }
        line[n] = '\0';
        line[strcspn(line, "\n")] = '\0';
        if (line[0] == 'Q') {
            close(server);
            dispatch_sync(dispatch_get_main_queue(), ^{ teardown(); });
            reply_and_close(client, "ok");
            return NULL;
        }
        char *copy = strdup(line);
        dispatch_async(dispatch_get_main_queue(), ^{
            char reply[512];
            handle(copy, reply, sizeof(reply));
            reply_and_close(client, reply);
            free(copy);
        });
    }
}

__attribute__((constructor))
static void border_probe_init(void)
{
    cid = SLSMainConnectionID();
    snprintf(socket_path, sizeof(socket_path), "/tmp/nori_border_%s.socket", getenv("USER") ?: "user");
    pthread_t thread;
    pthread_create(&thread, NULL, serve, NULL);
    pthread_detach(thread);
}
