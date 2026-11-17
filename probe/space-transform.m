// POC, not part of nori: can a plain process (no payload, SIP on) set a real Space's transform? See docs/WINDOWSERVER.md.
// Pane (trypane.app) pans and zooms its canvas this way: SLSBridgedSpaceSetTransformOperation from its own process.
// make space-transform-probe && build/space-transform <mode> [sx tx ty [options]] [sid]
//   get                          the active Space and SLSSpaceGetTransform for it
//   bridged  sx tx ty [opt] [sid] SLSBridgedSpaceSetTransformOperation, -performWithWMBridgeDelegate
//   fallback sx tx ty [opt] [sid] the same operation, -invokeFallback
//   direct   sx tx ty [sid]       SLSSpaceSetTransform on our own connection
//   anim [opt] [sid]             bridged: scale 1 → 0.8 → 1 around the screen's center, 60 frames each way, timed
//   own bridged|direct [level]   Pane's model: a Space of our own (absolute level, default 1) with a red test window,
//                                shown, then anim on it, then destroyed
// Scale goes around the origin, so a scale alone shrinks toward the top left. Every mode but get ends on identity
// after 1.5 s, unless NORI_KEEP=1.

#import <AppKit/AppKit.h>
#include <CoreGraphics/CoreGraphics.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <mach/mach_time.h>
#include <unistd.h>

extern int SLSMainConnectionID(void);
extern uint64_t SLSGetActiveSpace(int cid);
// Returns the struct (x8), the error goes through the pointer in x2.
extern CGAffineTransform SLSSpaceGetTransform(int cid, uint64_t sid, CGError *err);
extern CGError SLSSpaceSetTransform(int cid, uint64_t sid, CGAffineTransform t);

extern uint64_t SLSSpaceCreate(int cid, int one, CFDictionaryRef options);
extern CGError SLSSpaceDestroy(int cid, uint64_t sid);
extern CGError SLSSpaceSetAbsoluteLevel(int cid, uint64_t sid, int level);
extern void SLSSpaceAddWindowsAndRemoveFromSpaces(int cid, uint64_t sid, CFArrayRef wids, int mask);
extern void SLSShowSpaces(int cid, CFArrayRef sids);
extern void SLSHideSpaces(int cid, CFArrayRef sids);

static int cid;

static void report(uint64_t sid, const char *when) {
    CGError err = 0;
    CGAffineTransform t = SLSSpaceGetTransform(cid, sid, &err);
    printf("%s: sid %llu err %d  [a %.3f b %.3f c %.3f d %.3f tx %.1f ty %.1f]\n", when, sid, err, t.a, t.b, t.c, t.d, t.tx, t.ty);
}

static double now(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static id makeOp(uint64_t sid, CGAffineTransform t, uint32_t options) {
    Class cls = objc_getClass("SLSBridgedSpaceSetTransformOperation");
    if (!cls) { fprintf(stderr, "no SLSBridgedSpaceSetTransformOperation\n"); exit(1); }
    id op = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("alloc"));
    return ((id (*)(id, SEL, uint64_t, CGAffineTransform, uint32_t))objc_msgSend)(
        op, sel_registerName("initWithSpaceID:transform:options:"), sid, t, options);
}

static void perform(id op, const char *sel) { ((void (*)(id, SEL))objc_msgSend)(op, sel_registerName(sel)); }

static void bridged(uint64_t sid, CGAffineTransform t, uint32_t options) {
    @autoreleasepool { perform(makeOp(sid, t, options), "performWithWMBridgeDelegate"); }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        cid = SLSMainConnectionID();
        if (argc < 2) { fprintf(stderr, "usage: see the top of probe/space-transform.m\n"); return 2; }
        const char *mode = argv[1];
        uint64_t sid = SLSGetActiveSpace(cid);
        CGRect screen = CGDisplayBounds(CGMainDisplayID());
        double scale = (double)CGDisplayPixelsWide(CGMainDisplayID()) / screen.size.width; // ponytail: main display only
        if (!strcmp(mode, "get")) { report(sid, "now"); return 0; }

        bool own = !strcmp(mode, "own"), viaBridge = !(own && argc > 2 && !strcmp(argv[2], "direct"));
        NSWindow *win = nil;
        if (own) {
            [NSApplication sharedApplication];
            win = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 800, 500) styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
            win.backgroundColor = NSColor.systemRedColor;
            win.level = NSFloatingWindowLevel;
            [win orderFrontRegardless];
            [win display];
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
            sid = SLSSpaceCreate(cid, 1, NULL);
            int level = argc > 3 ? atoi(argv[3]) : 1;
            printf("own sid %llu, level %d: %d, window %ld\n", sid, level, SLSSpaceSetAbsoluteLevel(cid, sid, level), (long)win.windowNumber);
            SLSSpaceAddWindowsAndRemoveFromSpaces(cid, sid, (__bridge CFArrayRef)@[@(win.windowNumber)], 7);
            SLSShowSpaces(cid, (__bridge CFArrayRef)@[@(sid)]);
            usleep(300000);
        }
        if (own || !strcmp(mode, "anim")) {
            uint32_t options = own ? 0 : argc > 2 ? (uint32_t)atoi(argv[2]) : 0;
            if (!own && argc > 3) sid = strtoull(argv[3], NULL, 10);
            double cx = screen.size.width * scale / 2, cy = screen.size.height * scale / 2, worst = 0, total = 0;
            for (int i = 0; i <= 120; i++) {
                double p = i <= 60 ? i / 60.0 : (120 - i) / 60.0, s = 1 - 0.2 * p;
                CGAffineTransform t = {s, 0, 0, s, cx * (1 - s), cy * (1 - s)};
                // PEAK="s tx ty": the middle frame (the one SHOT captures) gets that transform instead.
                if (i == 60 && getenv("PEAK")) { sscanf(getenv("PEAK"), "%lf %lf %lf", &t.a, &t.tx, &t.ty); t.d = t.a; }
                double t0 = now();
                if (viaBridge) bridged(sid, t, options); else SLSSpaceSetTransform(cid, sid, t);
                double dt = now() - t0;
                worst = fmax(worst, dt); total += dt;
                if (i == 60) {
                    report(sid, "at 0.8");
                    if (getenv("SHOT")) system(getenv("SHOT"));
                    if (getenv("HOLD")) usleep((useconds_t)(atof(getenv("HOLD")) * 1e6)); // HOLD=seconds on the middle frame, to look at it
                }
                usleep(16000);
            }
            printf("perform: mean %.3f ms, worst %.3f ms over 121 calls\n", total / 121, worst);
            bridged(sid, CGAffineTransformIdentity, options);
            report(sid, "after");
            if (own) {
                SLSHideSpaces(cid, (__bridge CFArrayRef)@[@(sid)]);
                [win orderOut:nil];
                printf("destroy: %d\n", SLSSpaceDestroy(cid, sid));
            }
            return 0;
        }

        if (argc < 5) { fprintf(stderr, "%s needs sx tx ty\n", mode); return 2; }
        double s = atof(argv[2]), tx = atof(argv[3]), ty = atof(argv[4]);
        CGAffineTransform t = {s, 0, 0, s, tx, ty};
        uint32_t options = 0;
        if (!strcmp(mode, "direct")) { if (argc > 5) sid = strtoull(argv[5], NULL, 10); }
        else {
            if (argc > 5) options = (uint32_t)atoi(argv[5]);
            if (argc > 6) sid = strtoull(argv[6], NULL, 10);
        }
        report(sid, "before");
        if (!strcmp(mode, "bridged")) bridged(sid, t, options);
        else if (!strcmp(mode, "fallback")) { @autoreleasepool { perform(makeOp(sid, t, options), "invokeFallback"); } }
        else if (!strcmp(mode, "direct")) printf("SLSSpaceSetTransform: %d\n", SLSSpaceSetTransform(cid, sid, t));
        else { fprintf(stderr, "unknown mode %s\n", mode); return 2; }
        usleep(300000);
        report(sid, "after 0.3 s");
        if (getenv("NORI_KEEP")) return 0;
        usleep(1200000);
        if (!strcmp(mode, "direct")) SLSSpaceSetTransform(cid, sid, CGAffineTransformIdentity);
        else bridged(sid, CGAffineTransformIdentity, options);
        usleep(200000);
        report(sid, "reset");
    }
    return 0;
}
