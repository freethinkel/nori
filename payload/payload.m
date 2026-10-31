// nori payload: loaded into Dock.app by loader. Serves a line protocol on a unix socket.
// Lines: "S wid x y"         set target; payload eases the window there
//        "T wid a b c d tx ty"  transform
//        "M wid x y"           move (immediate)
//        "A wid alpha"         alpha (immediate)
//        "E wid from to"       alpha eases from `from` to `to`, on the same curve as S
//        "O wid order rel"     order
//        "D wid m11 m12 … m44"  3D transform (CATransform3D, row by row); identity resets
//        "Y spring target goal sid0 sid1 …"  Space layout, see step_layout: Spaces of the display top to bottom,
//                              the index to center, overview goal (1 open, 0 plain), and 1 to move on a spring
//                              (overview) or 0 to ease like windows (a Space switch)
//        "G progress velocity" a running Space layout follows a swipe: progress held there until the next "Y"
//        "F focus velocity"    the same for the (fractional) index of the Space at the center
//        "Q seq"               number of the next "Y", echoed back in its "layout-done"
//        "Z scale"             size of the Spaces in the overview, from the next frame on; comes before each "Y"
// Back to the daemon, on its control socket (daemon/Control.swift), see notify_daemon:
//        "payload\tlayout-done\t<seq>"             a Space layout ended; the strip may look at windows again
//        "payload\tresize-settled\t<wid>\t<width>"  a width stretch reached its goal; the app can be resized now
//        "R wid width"         width animation, see resize_t. S and M for that window move its center meanwhile.
//        "W wid width"         the app has resized that window to `width` (the end of a width animation)
//        "X wid sid"           move the window to Space sid
//        "P pid"               daemon pid. Vertical Spaces are on only while that process is alive.
//        "I 1|0"               instant: Dock's switch frames get identity transforms (no slide) until "I 0"
// Also turns the native Spaces slide vertical, see hook_space_transform.
// Animation runs here on a user-interactive queue, so the daemon sends one line per window, not one per frame.
// Frames come from CVDisplayLink (vsync), and each frame moves all windows in one SLS transaction.
// Only windows still moving stay in the table; a new target starts from the window's real position.
// ponytail: fixed table of 128 moving windows; display link runs while idle (empty tick), stop it if Dock CPU matters.

#include <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <ptrauth.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <signal.h>
#include <unistd.h>

extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
extern CGError SLSSetWindowTransform(int cid, uint32_t wid, CGAffineTransform t);
extern OSStatus SLSMoveWindowWithGroup(int cid, uint32_t wid, CGPoint *point);
// SLSMoveWindowWithGroup is exactly create + this + commit(0); point is passed by value (d0/d1).
extern CFTypeRef SLSTransactionCreate(int cid);
extern CGError SLSTransactionMoveWindowWithGroup(CFTypeRef transaction, uint32_t wid, CGPoint point);
extern CGError SLSTransactionCommit(CFTypeRef transaction, int synchronous);
extern CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha);
extern CGError SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);
// Works only from Dock's connection on macOS 27; the daemon's own connection gets the window left where it is.
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef wids, uint64_t sid);
// The matrix is 16 doubles, same layout as CATransform3D.
extern CGError SLSTransactionSetWindowTransform3D(CFTypeRef transaction, uint32_t wid, const double *m);
extern CGError SLSTransactionShowSpace(CFTypeRef transaction, uint64_t sid);
extern CGError SLSTransactionHideSpace(CFTypeRef transaction, uint64_t sid);
extern CGError SLSTransactionSetSpaceShape(CFTypeRef transaction, uint64_t sid, CFTypeRef region);
extern CGError SLSTransactionSetSpaceTransform(CFTypeRef transaction, uint64_t sid, uint32_t unknown, const CGAffineTransform *t);
extern CFTypeRef CGRegionCreateWithRect(CGRect rect);
extern bool CGRegionIsEmpty(CFTypeRef region);
extern CGError CGSGetRegionBounds(CFTypeRef region, CGRect *bounds);
extern uint64_t SLSGetActiveSpace(int cid);
extern int SLSSpaceGetType(int cid, uint64_t sid);  // 0 desktop, 4 fullscreen (an app's own Space)
extern CFArrayRef SLSCopySpacesForWindows(int cid, int mask, CFArrayRef wids);

#define MAX_ANIMS 128

typedef struct {
    uint32_t wid;
    CGPoint cur;
    CGPoint goal;
} anim_t;

static dispatch_queue_t queue;
static CVDisplayLinkRef display_link;
static anim_t anims[MAX_ANIMS];
static pid_t daemon_pid;

// While a Space layout runs, its transforms win over Dock's (Dock may be switching underneath).
// ponytail: written on the payload queue, read on Dock's threads without a lock; a torn read lasts one frame.
#define MAX_SPACES 32
static bool overview_active;
static struct { uint64_t sid; CGAffineTransform t; } overview[MAX_SPACES];
static int overview_count;
// Windows on every Space (a status bar, borders, PiP), found when a layout starts. WindowServer draws them with
// one Space, so they slid with it; hold_sticky takes that Space's transform back out.
static struct { uint32_t wid; CGPoint origin; } sticky[MAX_ANIMS];
static int sticky_count;
static __thread bool in_step_layout;  // the hook is called from step_layout, not by Dock
static bool dock_switching;           // Dock's own switch has begun and the current Space hasn't changed yet
static uint64_t dock_current;         // the Space Dock is making current (nori_current_space) until that is committed, or 0
static uint64_t dock_from;            // the current Space when Dock's switch began (dock_switch_began)
static CFTypeRef dock_first;          // Dock's transaction in which its switch began, until step_layout's next frame
static bool instant;                  // "I 1": Dock's switch gets identity transforms, so the new Space just appears

// Space layout: the overview and Space switches, animated here on vsync like windows.
// focus is the (fractional) index at the screen center; progress 0 is plain Spaces, 1 the overview.
// Dock still switches the current Space: the daemon presses its shortcut, and the hooks give Dock's frames ours.
static double overview_scale = 0.4;
#define OVERVIEW_GAP 48.0
#define SPRING_RESPONSE 0.28  // seconds per oscillation, like SwiftUI's .spring(response:dampingFraction:)
#define SPRING_DAMPING 0.78
static uint64_t layout_spaces[MAX_SPACES];
static int layout_count;  // 0: no layout running
static int layout_target;
static double layout_goal;
static bool layout_spring;
static bool layout_follow;  // a 4-finger swipe holds progress ("G"); the next "Y" lets go
static bool focus_follow;   // a 3-finger swipe holds focus ("F"); the next "Y" lets go
static double layout_focus, layout_progress, focus_velocity, progress_velocity;
// The last swipe value ("G", "F") and when it came (ns). Values come at the trackpad's rate, not the display's:
// shown as they come, some frames got none and the next two, so the layout chases where the finger is now.
static double finger_progress, finger_focus;
static uint64_t finger_progress_at, finger_focus_at;
static uint64_t layout_started;  // ns
static long layout_seq;          // from "Q", for "layout-done"
static char control_path[256];   // the daemon's control socket
static dispatch_queue_t notify_queue;

// One request per connection, like nori-msg. Off the animation queue, and dropped if the daemon isn't listening.
// The reply (none for these) is read to the end before closing, so the daemon never writes to a closed socket.
static void notify_daemon(const char *format, ...)
{
    char *line;
    va_list args;
    va_start(args, format);
    if (vasprintf(&line, format, args) < 0) line = NULL;
    va_end(args);
    if (!line) return;
    dispatch_async(notify_queue, ^{
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un addr = { .sun_family = AF_UNIX };
        snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", control_path);
        if (fd >= 0 && connect(fd, (struct sockaddr *) &addr, sizeof(addr)) == 0) {
            write(fd, line, strlen(line));
            char buf[256];
            while (read(fd, buf, sizeof(buf)) > 0) {}
        }
        if (fd >= 0) close(fd);
        free(line);
    });
}

static int anim_count;

// Width animations ("R"). The window is stretched by a transform from its real width to the drawn one, which eases
// to `goal`; the real window is kept centered on cx by a move in the same transaction.
// While the stretch eases, the real width is not read back: guessing it from SLSGetWindowBounds then made the stretch
// run away and the window land off center. The app keeps its width until the stretch settles; then the daemon
// resizes it and says so with "W", and the stretch is dropped. Once settled, the window's own width is watched too
// (see tick): the app draws its new width before "W" can come.
typedef struct {
    uint32_t wid;
    double drawn, goal, real;  // widths
    double cx, cx_goal;        // screen x of the center
    uint64_t started;
    bool notified;             // "resize-settled" sent for this goal
} resize_t;
static resize_t resizes[MAX_ANIMS];
static int resize_count;

static resize_t *resize_for(uint32_t wid)
{
    for (int i = 0; i < resize_count; i++) {
        if (resizes[i].wid == wid) return &resizes[i];
    }
    return NULL;
}

static anim_t *anim_for(uint32_t wid, bool create)
{
    for (int i = 0; i < anim_count; i++) {
        if (anims[i].wid == wid) return &anims[i];
    }
    if (!create || anim_count == MAX_ANIMS) return NULL;
    anims[anim_count] = (anim_t){0};
    return &anims[anim_count++];
}

static void anim_drop(uint32_t wid)
{
    for (int i = 0; i < anim_count; i++) {
        if (anims[i].wid == wid) { anims[i] = anims[--anim_count]; return; }
    }
}

// Alpha fades ("E"). The start comes from the daemon: it set the alpha it is fading from, so nothing is read back.
typedef struct {
    uint32_t wid;
    float cur, goal;
} fade_t;
static fade_t fades[MAX_ANIMS];
static int fade_count;

static void fade_drop(uint32_t wid)
{
    for (int i = 0; i < fade_count; i++) {
        if (fades[i].wid == wid) { fades[i] = fades[--fade_count]; return; }
    }
}

static void spring(double *x, double *velocity, double goal, double dt)
{
    double stiffness = pow(2 * M_PI / SPRING_RESPONSE, 2), friction = 4 * M_PI * SPRING_DAMPING / SPRING_RESPONSE;
    *velocity += (stiffness * (goal - *x) - friction * *velocity) * dt;
    *x += *velocity * dt;
}

// Halfway each frame to where the finger is by now: the last value moved on by its speed, at most 50 ms ahead
// so a pause in the values doesn't run off. ponytail: lags the finger by about a frame; less halving, less lag.
static void chase(double *x, double value, double velocity, uint64_t at, uint64_t now)
{
    *x += (value + velocity * fmin((now - at) / 1e9, 0.05) - *x) * 0.5;
}

// The Space the sticky windows go with: the one that last became shown (step_layout makes that the target), but
// from the start of Dock's own switch until the current Space changes the current one, as in Dock's slide (seen: they
// vanished while Dock's frames had stopped and the current Space was still the old one).
// A fullscreen Space doesn't take them in Dock's switch: they stay with the desktop side of it. Leaving one, they
// were drawn with the target desktop from the switch's start, while the current Space was still the fullscreen one
// (recorded: a status bar a whole Space off, -1692 pt, or -725 in the overview, for ~0.3 s until the change).
// ponytail: entering one, they are held with the desktop it came from; only seen as a 0.12 s jump, not traced.
static bool is_fullscreen(uint64_t sid) { return SLSSpaceGetType(SLSMainConnectionID(), sid) == 4; }

static uint64_t held_space(void)
{
    uint64_t target = layout_spaces[layout_target];
    if (!dock_switching) return target;
    uint64_t current = SLSGetActiveSpace(SLSMainConnectionID());
    if (!is_fullscreen(current)) return current;
    if (!is_fullscreen(target)) return target;
    return dock_from && !is_fullscreen(dock_from) ? dock_from : current;
}

// Dock's frames came in during this layout: its own switch has begun. Called from Dock's threads (the hooks).
static void dock_switch_began(void)
{
    if (dock_switching) return;
    dock_from = SLSGetActiveSpace(SLSMainConnectionID());
    dock_switching = true;
}

// One frame of the Space layout. It ends once it has settled back at plain Spaces and Dock's switch is over
// (or after a second): only the centered Space stays shown, untransformed, and Dock animates on its own again.
// dt is one display frame, not the time since the last callback: callbacks come unevenly, frames don't.
static void step_layout(double dt)
{
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    dock_first = NULL;  // Dock's first switch frame is behind us; its transaction's address may be reused
    if (layout_follow) chase(&layout_progress, finger_progress, progress_velocity, finger_progress_at, now);
    if (focus_follow) chase(&layout_focus, finger_focus, focus_velocity, finger_focus_at, now);
    if (layout_spring) {
        for (; dt > 0; dt -= 1.0 / 240) {  // small substeps keep the spring stable
            if (!layout_follow) spring(&layout_progress, &progress_velocity, layout_goal, fmin(dt, 1.0 / 240));
            if (!focus_follow) spring(&layout_focus, &focus_velocity, layout_target, fmin(dt, 1.0 / 240));
        }
    } else {
        if (!layout_follow) layout_progress += (layout_goal - layout_progress) * 0.25;
        if (!focus_follow) layout_focus += (layout_target - layout_focus) * 0.25;
        if (!layout_follow) progress_velocity = 0;
        if (!focus_follow) focus_velocity = 0;
    }
    bool settled = !layout_follow && !focus_follow && fabs(layout_goal - layout_progress) < 0.001 && fabs(layout_target - layout_focus) < 0.001
        && fabs(progress_velocity) < 0.01 && fabs(focus_velocity) < 0.01;
    if (settled) {
        layout_progress = layout_goal;
        layout_focus = layout_target;
    }
    uint64_t current = SLSGetActiveSpace(SLSMainConnectionID());
    // Dock's change is committed: this frame takes the sticky windows to the target, see nori_current_space. Not into
    // a fullscreen Space: they don't go there, and stay with the desktop side (held_space) until the next switch.
    if (current == dock_current && !is_fullscreen(current)) {
        dock_switching = false;
        dock_current = 0;
    }
    bool done = settled && layout_goal == 0 && (current == layout_spaces[layout_target] || now - layout_started > 1000000000);
    // Our slide is over, Dock's switch isn't: the sticky windows still go with the old Space (held_space). It is put
    // where the target is, under it, so that when the current Space changes they pass from one untransformed Space
    // to another. With the old Space a screen away they left the screen for 2–4 frames at that change (recorded).
    bool old_home = settled && layout_goal == 0 && dock_switching && current != layout_spaces[layout_target];

    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
    if (!transaction) return;
    CGRect screen = CGDisplayBounds(CGMainDisplayID());
    CFTypeRef region = CGRegionCreateWithRect(screen);
    double scale = 1 - (1 - overview_scale) * layout_progress;
    overview_count = layout_count;  // before the transforms: the hook looks each one up, the first frame's too
    // Their own frames every frame: one may move meanwhile (a PiP dragged), and the hook undoes from these.
    for (int i = 0; i < sticky_count; i++) {
        CGRect frame;
        if (SLSGetWindowBounds(SLSMainConnectionID(), sticky[i].wid, &frame) == kCGErrorSuccess) sticky[i].origin = frame.origin;
    }
    in_step_layout = true;
    for (int k = 1; k <= layout_count; k++) {  // the target last
        int i = (layout_target + k) % layout_count;
        uint64_t sid = layout_spaces[i];
        // Space transforms map screen to Space: the inverse of "scale about the screen center, then move down".
        double center_y = CGRectGetMidY(screen) + (i - layout_focus) * (screen.size.height * scale + OVERVIEW_GAP * layout_progress);
        CGAffineTransform t = { 1 / scale, 0, 0, 1 / scale,
                                CGRectGetMidX(screen) * (1 - 1 / scale), CGRectGetMidY(screen) - center_y / scale };
        // Unscaled, a whole-point slide: a fractional one and the sticky windows' undoing of it were rounded to
        // pixels each its own way, and the windows shook by a pixel.
        if (scale == 1) t.ty = round(t.ty);
        if (done || (old_home && sid == current)) t = CGAffineTransformIdentity;
        if (!done || i == layout_target) {
            // Sticky windows go with the Space that last became shown; showing a shown one again doesn't count.
            // So the target is hidden and shown again, in the same transaction, after the others, which also keeps
            // it on top. During Dock's switch they go with the current Space whatever was shown, and are drawn
            // over every Space anyway (docs/WINDOWSERVER.md).
            if (i == layout_target) SLSTransactionHideSpace(transaction, sid);
            // Re-shown every frame: Dock hides the old Space when its switch ends, ours may still be sliding.
            SLSTransactionShowSpace(transaction, sid);
            SLSTransactionSetSpaceShape(transaction, sid, region);
        } else {
            SLSTransactionHideSpace(transaction, sid);
        }
        overview[i].sid = sid;
        overview[i].t = t;
        SLSTransactionSetSpaceTransform(transaction, sid, 4, &t);  // 4: what Dock passes
    }
    in_step_layout = false;
    if (done) {
        overview_active = false;
        overview_count = 0;
        layout_count = 0;
        notify_daemon("payload\tlayout-done\t%ld\n", layout_seq);
    }
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
    CFRelease(region);
}

// Drops a settled stretch whose app has the goal width now, recentered, in a transaction of its own right away.
// from_bounds: take the real width from the window's bounds (the app's resize shows there the frame it lands, see
// tick); otherwise it was just set from "W". Returns true if dropped: the entry is gone, resizes[i] is another one.
static bool finish_resize(int i, int cid, bool from_bounds)
{
    resize_t *r = &resizes[i];
    CGRect b;
    if (fabs(r->goal - r->drawn) >= 0.5 || SLSGetWindowBounds(cid, r->wid, &b) != kCGErrorSuccess) return false;
    if (from_bounds && fabs(b.size.width - r->real) >= 1) r->real = b.size.width;
    if (fabs(r->real - r->goal) >= 1) return false;
    CFTypeRef transaction = SLSTransactionCreate(cid);
    if (!transaction) return false;
    double identity[16] = { 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1 };
    SLSTransactionMoveWindowWithGroup(transaction, r->wid, CGPointMake(r->cx - r->real / 2, b.origin.y));
    SLSTransactionSetWindowTransform3D(transaction, r->wid, identity);
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
    *r = resizes[--resize_count];
    return true;
}

// While a settled stretch waits for its app, its width is checked every millisecond, not once a frame: an app commits
// its resize mid-frame, and a frame composited before the next tick drew the new width stretched again, wider than
// the goal (seen as a flicker at the end of an Option+drag resize). Runs only while one waits.
static dispatch_source_t resize_watch;

static void watch_resizes(void)
{
    int cid = SLSMainConnectionID();
    bool waiting = false;
    for (int i = 0; i < resize_count;) {
        if (finish_resize(i, cid, true)) continue;
        if (fabs(resizes[i].goal - resizes[i].drawn) < 0.5) waiting = true;
        i++;
    }
    if (!waiting && resize_watch) {
        dispatch_source_cancel(resize_watch);
        dispatch_release(resize_watch);
        resize_watch = NULL;
    }
}

static void start_resize_watch(void)
{
    if (resize_watch) return;
    resize_watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(resize_watch, DISPATCH_TIME_NOW, NSEC_PER_MSEC, 100 * NSEC_PER_USEC);
    dispatch_source_set_event_handler(resize_watch, ^{ watch_resizes(); });
    dispatch_resume(resize_watch);
}

// A layout whose daemon is gone (a crash) would stay on: nothing sends the closing "Y", and the event tap went with
// the daemon. It closes on the Space Dock has current, asked every frame as Dock may still be switching, and
// step_layout ends it like any other, which puts Spaces and sticky windows back.
static void close_orphan_layout(void)
{
    if (!daemon_pid || kill(daemon_pid, 0) == 0) return;
    uint64_t current = SLSGetActiveSpace(SLSMainConnectionID());
    for (int i = 0; i < layout_count; i++) if (layout_spaces[i] == current) layout_target = i;
    layout_goal = 0;
    layout_spring = layout_follow = focus_follow = false;
}

static void tick(double frame)
{
    if (layout_count) {
        close_orphan_layout();
        step_layout(frame);
    }
    int kept_fades = 0;
    for (int i = 0; i < fade_count; i++) {
        fade_t f = fades[i];
        f.cur += (f.goal - f.cur) * 0.25f;
        if (fabsf(f.goal - f.cur) < 0.005f) f.cur = f.goal; else fades[kept_fades++] = f;
        SLSSetWindowAlpha(SLSMainConnectionID(), f.wid, f.cur);
    }
    fade_count = kept_fades;
    if (!anim_count && !resize_count) return;
    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
    if (!transaction) return;
    int kept = 0;
    for (int i = 0; i < anim_count; i++) {
        anim_t a = anims[i];
        CGFloat dx = a.goal.x - a.cur.x, dy = a.goal.y - a.cur.y;
        if (fabs(dx) < 0.5 && fabs(dy) < 0.5) {
            a.cur = a.goal;
        } else {
            a.cur.x += dx * 0.25;
            a.cur.y += dy * 0.25;
            anims[kept++] = a;
        }
        SLSTransactionMoveWindowWithGroup(transaction, a.wid, a.cur);
    }
    anim_count = kept;
    kept = 0;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (int i = 0; i < resize_count; i++) {
        resize_t r = resizes[i];
        CGRect b;
        if (SLSGetWindowBounds(SLSMainConnectionID(), r.wid, &b) != kCGErrorSuccess) continue;  // closed
        r.drawn += (r.goal - r.drawn) * 0.25;
        r.cx += (r.cx_goal - r.cx) * 0.25;
        bool settled = fabs(r.goal - r.drawn) < 0.5 && fabs(r.cx_goal - r.cx) < 0.5;
        if (settled) {
            r.drawn = r.goal;
            r.cx = r.cx_goal;
            // The app's resize shows in its bounds the frame it lands (SLSGetWindowBounds leaves window transforms out:
            // 600 under a 1.5x stretch, 900 within ~12 ms of the app's setFrame, measured). "W" comes an AX round trip
            // later, and each frame until then was drawn stretched twice: wider than the goal for a frame or more.
            if (fabs(b.size.width - r.real) >= 1) r.real = b.size.width;
        }
        // Done once the app has the width; after two seconds without "W" the daemon is gone or the app is stuck.
        bool done = settled && (fabs(r.real - r.goal) < 1 || now - r.started > 2000000000);
        if (settled && !done && !r.notified) {
            r.notified = true;
            notify_daemon("payload\tresize-settled\t%u\t%.1f\n", r.wid, r.goal);
        }
        double s = done ? 1 : r.drawn / r.real;
        SLSTransactionMoveWindowWithGroup(transaction, r.wid, CGPointMake(r.cx - r.real / 2, b.origin.y));
        // Screen -> window matrix, origin at the window's top-left (docs/WINDOWSERVER.md): x scaled about the center.
        double m[16] = { 1 / s, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  r.real / 2 * (1 - 1 / s), 0, 0, 1 };
        SLSTransactionSetWindowTransform3D(transaction, r.wid, m);
        if (!done) resizes[kept++] = r;
        if (!done && settled) start_resize_watch();
    }
    resize_count = kept;
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}

static CVReturn on_frame(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *out, CVOptionFlags in, CVOptionFlags *flags, void *ctx)
{
    double frame = out->videoRefreshPeriod && out->videoTimeScale ? (double) out->videoRefreshPeriod / out->videoTimeScale : 1.0 / 60;
    dispatch_sync(queue, ^{ tick(frame); });
    return kCVReturnSuccess;
}

static int sticky_index(uint32_t wid)
{
    for (int i = 0; i < sticky_count; i++) if (sticky[i].wid == wid) return i;
    return -1;
}

// Adds the sticky windows on the main display (the one the layout moves) to the list. One stays in it until the
// layout ends, even if ordered out meanwhile, so it gets its identity back then. Desktop-level windows (Finder's
// icons) are left out. Frames from SLSGetWindowBounds: CGWindowList's have the Space transform and ours in them.
static void find_sticky(int cid)
{
    CGRect screen = CGDisplayBounds(CGMainDisplayID());
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (CFIndex i = 0; windows && i < CFArrayGetCount(windows) && sticky_count < MAX_ANIMS; i++) {
        CFDictionaryRef window = CFArrayGetValueAtIndex(windows, i);
        CFNumberRef number = CFDictionaryGetValue(window, kCGWindowNumber);
        int layer = 0;
        uint32_t wid = 0;
        CGRect frame;
        CFNumberGetValue(CFDictionaryGetValue(window, kCGWindowLayer), kCFNumberIntType, &layer);
        if (layer < 0 || !CFNumberGetValue(number, kCFNumberSInt32Type, &wid) || sticky_index(wid) >= 0
            || SLSGetWindowBounds(cid, wid, &frame) != kCGErrorSuccess
            || !CGRectContainsPoint(screen, CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame)))) continue;
        CFArrayRef list = CFArrayCreate(NULL, (const void **) &number, 1, &kCFTypeArrayCallBacks);
        CFArrayRef spaces = SLSCopySpacesForWindows(cid, 7, list);  // 7: all Spaces
        if (spaces && CFArrayGetCount(spaces) > 1) sticky[sticky_count++] = (typeof(sticky[0])){ wid, frame.origin };
        if (spaces) CFRelease(spaces);
        CFRelease(list);
    }
    if (windows) CFRelease(windows);
}

static void handle_line(char *line)
{
    int cid = SLSMainConnectionID();
    uint32_t wid;
    switch (line[0]) {
    case 'S': {
        CGPoint goal;
        if (sscanf(line + 1, "%u %lf %lf", &wid, &goal.x, &goal.y) == 3) {
            resize_t *r = resize_for(wid);
            if (r) { r->cx_goal = goal.x + r->goal / 2; break; }  // the resize owns this window's position
            anim_t *a = anim_for(wid, true);
            if (!a) break;
            if (a->wid != wid) {
                CGRect frame;
                a->wid = wid;
                a->cur = SLSGetWindowBounds(cid, wid, &frame) == kCGErrorSuccess ? frame.origin : goal;
            }
            a->goal = goal;
        }
        break;
    }
    case 'T': {
        CGAffineTransform t;
        if (sscanf(line + 1, "%u %lf %lf %lf %lf %lf %lf", &wid, &t.a, &t.b, &t.c, &t.d, &t.tx, &t.ty) == 7) {
            SLSSetWindowTransform(cid, wid, t);
        }
        break;
    }
    case 'M': {
        CGPoint p;
        if (sscanf(line + 1, "%u %lf %lf", &wid, &p.x, &p.y) == 3) {
            resize_t *r = resize_for(wid);
            if (r) { r->cx = r->cx_goal = p.x + r->goal / 2; break; }
            anim_drop(wid);  // a running ease would pull the window back every frame
            SLSMoveWindowWithGroup(cid, wid, &p);
        }
        break;
    }
    case 'A': {
        float alpha;
        if (sscanf(line + 1, "%u %f", &wid, &alpha) == 2) {
            fade_drop(wid);  // a running fade would overwrite it next frame
            SLSSetWindowAlpha(cid, wid, alpha);
        }
        break;
    }
    case 'E': {
        float from, to;
        if (sscanf(line + 1, "%u %f %f", &wid, &from, &to) == 3) {
            fade_t *f = NULL;
            for (int i = 0; i < fade_count; i++) if (fades[i].wid == wid) f = &fades[i];
            if (!f) {
                if (fade_count == MAX_ANIMS) { SLSSetWindowAlpha(cid, wid, to); break; }
                f = &fades[fade_count++];
                *f = (fade_t){ wid, from, to };
            }
            f->goal = to;  // a running fade keeps its current alpha and turns to the new goal
        }
        break;
    }
    case 'O': {
        int order;
        uint32_t rel;
        if (sscanf(line + 1, "%u %d %u", &wid, &order, &rel) == 3) {
            SLSOrderWindow(cid, wid, order, rel);
        }
        break;
    }
    case 'Y': {
        char *rest;
        bool use_spring = strtol(line + 1, &rest, 10);
        int target = (int) strtol(rest, &rest, 10);
        double goal = strtod(rest, &rest);
        uint64_t spaces[MAX_SPACES];
        int count = 0;
        for (char *end; count < MAX_SPACES; rest = end) {
            uint64_t sid = strtoull(rest, &end, 10);
            if (end == rest) break;
            spaces[count++] = sid;
        }
        if (target < 0 || target >= count) break;
        if (!layout_count) {
            // Start from what is on screen now: the current Space centered, no overview.
            uint64_t active = SLSGetActiveSpace(cid);
            layout_focus = target;
            for (int i = 0; i < count; i++) if (spaces[i] == active) layout_focus = i;
            layout_progress = progress_velocity = focus_velocity = 0;
            sticky_count = 0;
            dock_switching = false;
            dock_current = 0;
            dock_from = 0;
            dock_first = NULL;
        }
        find_sticky(cid);  // every "Y": one opened meanwhile (a PiP) is held from here on
        memcpy(layout_spaces, spaces, sizeof(spaces));
        layout_count = count;
        layout_target = target;
        layout_goal = goal;
        layout_spring = use_spring;
        layout_follow = false;
        focus_follow = false;
        layout_started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        overview_active = true;
        break;
    }
    case 'F': {
        // Same as "G" for the Space at the center: a 3-finger swipe moves through Spaces.
        double focus, velocity;
        if (layout_count && sscanf(line + 1, "%lf %lf", &focus, &velocity) == 2) {
            finger_focus = focus;
            focus_velocity = velocity;
            focus_follow = true;
            layout_started = finger_focus_at = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        }
        break;
    }
    case 'G': {
        // The swipe leads progress (see chase) and sets its speed, per second, so a following "Y" springs on with it.
        double progress, velocity;
        if (layout_count && sscanf(line + 1, "%lf %lf", &progress, &velocity) == 2) {
            finger_progress = progress;
            progress_velocity = velocity;
            layout_follow = true;
            layout_started = finger_progress_at = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        }
        break;
    }
    case 'P': {
        pid_t pid = atoi(line + 1);
        if (pid != daemon_pid) instant = false;  // a daemon that died within the second of its "I 1" sends no "I 0"
        daemon_pid = pid;
        break;
    }
    case 'I':
        instant = atoi(line + 1);
        break;
    case 'Q':
        layout_seq = atol(line + 1);
        break;
    case 'Z': {
        double scale = strtod(line + 1, NULL);
        if (scale > 0 && scale <= 1) overview_scale = scale;  // the transforms divide by it
        break;
    }
    case 'R': {
        double width;
        if (sscanf(line + 1, "%u %lf", &wid, &width) == 2 && width > 0) {
            resize_t *r = resize_for(wid);
            if (!r) {
                CGRect b;
                if (resize_count == MAX_ANIMS || SLSGetWindowBounds(cid, wid, &b) != kCGErrorSuccess) break;
                r = &resizes[resize_count++];
                // No resize running, so no transform: these bounds are the real ones.
                *r = (resize_t){ wid, b.size.width, width, b.size.width, CGRectGetMidX(b), CGRectGetMidX(b), 0 };
            }
            r->goal = width;
            r->notified = false;
            r->started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            anim_drop(wid);  // the resize moves this window now
        }
        break;
    }
    case 'X': {
        unsigned long long sid;
        if (sscanf(line + 1, "%u %llu", &wid, &sid) == 2) {
            anim_drop(wid);
            CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
            CFArrayRef list = CFArrayCreate(NULL, (const void **) &number, 1, &kCFTypeArrayCallBacks);
            SLSMoveWindowsToManagedSpace(cid, list, sid);
            CFRelease(list);
            CFRelease(number);
        }
        break;
    }
    case 'W': {
        double width;
        if (sscanf(line + 1, "%u %lf", &wid, &width) == 2 && width > 0) {
            resize_t *r = resize_for(wid);
            if (!r) break;
            r->real = width;
            // The app already shows the new width, and the stretch on top of it would draw it scaled twice until
            // the next frame: if the stretch has settled there, drop it and recenter now.
            finish_resize((int) (r - resizes), cid, false);
        }
        break;
    }
    case 'D': {
        double m[16];
        if (sscanf(line + 1, "%u %lf %lf %lf %lf %lf %lf %lf %lf %lf %lf %lf %lf %lf %lf %lf %lf", &wid,
                   &m[0], &m[1], &m[2], &m[3], &m[4], &m[5], &m[6], &m[7],
                   &m[8], &m[9], &m[10], &m[11], &m[12], &m[13], &m[14], &m[15]) == 17) {
            CFTypeRef transaction = SLSTransactionCreate(cid);
            if (!transaction) break;
            SLSTransactionSetWindowTransform3D(transaction, wid, m);
            SLSTransactionCommit(transaction, 0);
            CFRelease(transaction);
        }
        break;
    }
    }
}

static void *serve(void *arg)
{
    const char *path = (const char *) arg;
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
    unlink(path);
    if (bind(server, (struct sockaddr *) &addr, sizeof(addr)) != 0 || listen(server, 4) != 0) {
        return NULL;
    }
    for (;;) {
        int client = accept(server, NULL, NULL);
        if (client < 0) continue;
        char buf[4096];
        ssize_t n;
        while ((n = read(client, buf, sizeof(buf) - 1)) > 0) {
            buf[n] = '\0';
            char *saveptr;
            for (char *line = strtok_r(buf, "\n", &saveptr); line; line = strtok_r(NULL, "\n", &saveptr)) {
                char *copy = strdup(line);
                dispatch_async(queue, ^{ handle_line(copy); free(copy); });
            }
        }
        close(client);
    }
    return NULL;
}

// Vertical Spaces and the overview. Each frame of a Space switch Dock calls, for both Spaces,
// SLSTransactionSetSpaceTransform(transaction, sid, u32, const CGAffineTransform *) with a horizontal slide and
// SLSTransactionSetSpaceShape(transaction, sid, CGRegionRef) with a matching horizontal clip.
// Dock's __DATA_CONST (its import table) can't be made writable, so we patch each function's first 16 bytes
// in Dock's copy of SkyLight: "ldr x16, #8; br x16; <stub>". The stub swaps one argument for ours,
// runs the 4 displaced prologue instructions and jumps back to fn + 16.
// Works because Dock is CS_DEBUGGED after injection, so a modified code page doesn't kill it.
// ponytail: prologues are checked byte for byte; another macOS build with different ones keeps horizontal spaces.
// ponytail: main display aspect only; spaces on a display with another aspect slide the wrong distance.
__attribute__((visibility("hidden"))) void *nori_transform_resume, *nori_shape_resume, *nori_current_resume, *nori_hide_resume;
extern char nori_transform_stub[], nori_transform_prologue[], nori_shape_stub[], nori_shape_prologue[];
extern char nori_current_stub[], nori_current_prologue[], nori_hide_stub[], nori_hide_prologue[];

static bool daemon_alive(void)
{
    // The patch stays in Dock after the daemon quits or crashes; Dock's own animation comes back then.
    return daemon_pid && kill(daemon_pid, 0) == 0;
}

// Undoing the held Space's transform (held_space), ours or Dock's, puts the sticky windows back where they are.
// WindowServer draws a window of a transformed Space from a whole point, so that is what gets undone: undoing the
// exact place left them a fraction of a point off, blurred, and shaking as the fraction changed. Up to 1/256 below a
// whole point counts as that point (docs/WINDOWSERVER.md).
static double undo_offset(double origin, double t, double a)
{
    double o = floor(origin);
    return floor((o - t) / a + 1.0 / 256) - o;
}

static void hold_sticky(CFTypeRef transaction, const CGAffineTransform *t)
{
    for (int i = 0; i < sticky_count; i++) {
        CGPoint o = sticky[i].origin;
        // Screen -> window, origin at the window's top-left (docs/WINDOWSERVER.md), after t (screen -> Space): t undone.
        double m[16] = { 1 / t->a, 0, 0, 0,  0, 1 / t->d, 0, 0,  0, 0, 1, 0,  undo_offset(o.x, t->tx, t->a), undo_offset(o.y, t->ty, t->d), 0, 1 };
        SLSTransactionSetWindowTransform3D(transaction, sticky[i].wid, m);
    }
}

// Pure horizontal translations (the slide) become vertical. Scaled ones (Mission Control) pass through.
__attribute__((visibility("hidden"), used))
const CGAffineTransform *nori_space_transform(const CGAffineTransform *t, uint64_t sid, CFTypeRef transaction)
{
    static __thread CGAffineTransform vertical;
    // A layout runs to its end even if the daemon is gone, so the sticky windows get their identity back.
    if (overview_active) {
        // Dock's first frame: the sticky windows still go with the Space that last became shown (the target), and
        // over to the current one from the next frame (recorded in the overview: a frame one slot off, -725, when
        // this frame already undid the current one). Dock transforms both Spaces in that transaction.
        if (!in_step_layout && !dock_switching) dock_first = transaction;
        if (!in_step_layout) dock_switch_began();
        uint64_t held = transaction == dock_first ? layout_spaces[layout_target] : held_space();
        for (int i = 0; i < overview_count; i++) {
            if (overview[i].sid != sid) continue;
            if (sid == held) hold_sticky(transaction, &overview[i].t);
            return &overview[i].t;
        }
    }
    if (!daemon_alive()) return t;
    if (instant) return &CGAffineTransformIdentity;  // no slide: both Spaces in place, the shown one on top
    if (!t || t->a != 1 || t->b != 0 || t->c != 0 || t->d != 1 || t->tx == 0) return t;
    CGRect screen = CGDisplayBounds(CGMainDisplayID());
    vertical = *t;
    vertical.ty += t->tx * screen.size.height / screen.size.width;
    vertical.tx = 0;
    return &vertical;
}

// SLSTransactionSetManagedDisplayCurrentSpace(transaction, display uuid, sid): the last call of Dock's switch. The old
// Space stays shown (nori_hide_space), so the sticky windows stay on it once this is committed, and they stay undone
// for it: undoing the new Space here left them off screen until the next step_layout, 25-30 ms later (recorded), and
// hiding and showing it here does nothing, it comes before the change. That step_layout takes them over in one
// transaction. The switch ends then, not at the next "Y": the overview is one layout through many switches.
__attribute__((visibility("hidden"), used))
void nori_current_space(CFTypeRef transaction, uint64_t sid)
{
    (void) transaction;
    if (overview_active) dock_current = sid;
}

// SLSTransactionHideSpace(transaction, sid): Dock hides the Space it leaves in the transaction that ends its switch,
// and entering a fullscreen Space it hides every desktop. Mid-layout that blanked those Spaces for a frame, until
// step_layout showed them again (recorded in the overview: one Space, or all desktops, gone for one sample). While
// a layout runs its Spaces are ours: Dock's hides of them are dropped, and step_layout hides them when it ends.
// Returns 1 to drop the call (the stub returns kCGErrorSuccess without running it).
__attribute__((visibility("hidden"), used))
int nori_hide_space(uint64_t sid)
{
    if (!overview_active || in_step_layout) return 0;
    for (int i = 0; i < overview_count; i++) if (overview[i].sid == sid) return 1;
    return 0;
}

// A full-height clip narrower than the screen (the slide) becomes a full-width one, scaled like the transform.
// ponytail: uses the region's bounding box; fine for Dock's rectangular slide clips.
__attribute__((visibility("hidden"), used))
CFTypeRef nori_space_shape(CFTypeRef region, uint64_t sid)
{
    static __thread CFTypeRef replaced;
    if (!region || !daemon_alive()) return region;
    CGRect screen = CGDisplayBounds(CGMainDisplayID());
    CGRect box;
    if (overview_active || instant) {
        box = screen;
    } else {
        if (CGRegionIsEmpty(region) || CGSGetRegionBounds(region, &box) != kCGErrorSuccess) return region;
        if (box.size.height < screen.size.height || box.size.width >= screen.size.width) return region;
        CGFloat k = screen.size.height / screen.size.width;
        box = CGRectMake(screen.origin.x, screen.origin.y + (box.origin.x - screen.origin.x) * k, screen.size.width, box.size.width * k);
    }
    if (replaced) CFRelease(replaced);
    replaced = CGRegionCreateWithRect(box);
    return replaced;
}

// Each stub: save the args, call the C function with (the arg to swap, sid), put its result in place of that arg,
// restore the rest and fall into the original prologue.
__asm__(
    ".text\n"
    ".p2align 2\n"
    ".private_extern _nori_transform_stub\n"
    "_nori_transform_stub:\n"
    "    stp x29, x30, [sp, #-48]!\n"
    "    mov x29, sp\n"
    "    stp x0, x1, [sp, #16]\n"
    "    stp x2, x3, [sp, #32]\n"
    "    mov x2, x0\n"  // the transaction
    "    mov x0, x3\n"  // x1 is sid
    "    bl _nori_space_transform\n"
    "    mov x3, x0\n"
    "    ldp x0, x1, [sp, #16]\n"
    "    ldr x2, [sp, #32]\n"
    "    ldp x29, x30, [sp], #48\n"
    ".private_extern _nori_transform_prologue\n"
    "_nori_transform_prologue:\n"
    "    pacibsp\n"
    "    stp d9, d8, [sp, #-0x40]!\n"
    "    stp x22, x21, [sp, #0x10]\n"
    "    stp x20, x19, [sp, #0x20]\n"
    "    adrp x16, _nori_transform_resume@PAGE\n"
    "    ldr x16, [x16, _nori_transform_resume@PAGEOFF]\n"
    "    br x16\n"
    ".p2align 2\n"
    ".private_extern _nori_shape_stub\n"
    "_nori_shape_stub:\n"
    "    stp x29, x30, [sp, #-32]!\n"
    "    mov x29, sp\n"
    "    stp x0, x1, [sp, #16]\n"
    "    mov x0, x2\n"  // x1 is sid
    "    bl _nori_space_shape\n"
    "    mov x2, x0\n"
    "    ldp x0, x1, [sp, #16]\n"
    "    ldp x29, x30, [sp], #32\n"
    ".private_extern _nori_shape_prologue\n"
    "_nori_shape_prologue:\n"
    "    pacibsp\n"
    "    sub sp, sp, #0x50\n"
    "    stp x22, x21, [sp, #0x20]\n"
    "    stp x20, x19, [sp, #0x30]\n"
    "    adrp x16, _nori_shape_resume@PAGE\n"
    "    ldr x16, [x16, _nori_shape_resume@PAGEOFF]\n"
    "    br x16\n"
    ".p2align 2\n"
    ".private_extern _nori_current_stub\n"
    "_nori_current_stub:\n"
    "    stp x29, x30, [sp, #-48]!\n"
    "    mov x29, sp\n"
    "    stp x0, x1, [sp, #16]\n"
    "    str x2, [sp, #32]\n"
    "    mov x1, x2\n"  // (transaction, sid)
    "    bl _nori_current_space\n"
    "    ldp x0, x1, [sp, #16]\n"
    "    ldr x2, [sp, #32]\n"
    "    ldp x29, x30, [sp], #48\n"
    ".private_extern _nori_current_prologue\n"
    "_nori_current_prologue:\n"
    "    pacibsp\n"
    "    stp x22, x21, [sp, #-0x30]!\n"
    "    stp x20, x19, [sp, #0x10]\n"
    "    stp x29, x30, [sp, #0x20]\n"
    "    adrp x16, _nori_current_resume@PAGE\n"
    "    ldr x16, [x16, _nori_current_resume@PAGEOFF]\n"
    "    br x16\n"
    // Not a swap: nori_hide_space says whether to skip the call. Skipped, it returns 0 (kCGErrorSuccess) to the
    // caller straight away; nothing was signed yet (pacibsp is in the prologue), so a plain ret is right.
    ".p2align 2\n"
    ".private_extern _nori_hide_stub\n"
    "_nori_hide_stub:\n"
    "    stp x29, x30, [sp, #-32]!\n"
    "    mov x29, sp\n"
    "    stp x0, x1, [sp, #16]\n"
    "    mov x0, x1\n"  // the sid
    "    bl _nori_hide_space\n"
    "    mov x9, x0\n"
    "    ldp x0, x1, [sp, #16]\n"
    "    ldp x29, x30, [sp], #32\n"
    "    cbnz w9, 1f\n"
    "    b _nori_hide_prologue\n"
    "1:\n"
    "    mov w0, #0\n"  // kept shown: no hide, no error
    "    ret\n"
    ".private_extern _nori_hide_prologue\n"
    "_nori_hide_prologue:\n"
    "    pacibsp\n"
    "    stp x20, x19, [sp, #-0x20]!\n"
    "    stp x29, x30, [sp, #0x10]\n"
    "    add x29, sp, #0x10\n"
    "    adrp x16, _nori_hide_resume@PAGE\n"
    "    ldr x16, [x16, _nori_hide_resume@PAGEOFF]\n"
    "    br x16\n"
);

static void hook(const char *name, char *prologue, void *stub, void **resume)
{
    uint8_t *fn = ptrauth_strip(dlsym(RTLD_DEFAULT, name), ptrauth_key_asia);
    if (!fn || memcmp(fn, prologue, 16) != 0) {
        NSLog(@"nori: %s not hooked: prologue differs", name);
        return;
    }
    *resume = fn + 16;
    uint32_t patch[4] = { 0x58000050, 0xd61f0200 };  // ldr x16, #8; br x16
    memcpy(&patch[2], &stub, sizeof(stub));

    // Stop Dock's other threads so none runs code on the page while it is writable.
    thread_act_array_t threads;
    mach_msg_type_number_t count = 0;
    thread_t self = mach_thread_self();
    task_threads(mach_task_self(), &threads, &count);
    for (mach_msg_type_number_t i = 0; i < count; i++) if (threads[i] != self) thread_suspend(threads[i]);

    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t) fn, sizeof(patch), false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr == KERN_SUCCESS) {
        memcpy(fn, patch, sizeof(patch));
        kr = vm_protect(mach_task_self(), (vm_address_t) fn, sizeof(patch), false, VM_PROT_READ | VM_PROT_EXECUTE);
        sys_icache_invalidate(fn, sizeof(patch));
    }

    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (threads[i] != self) thread_resume(threads[i]);
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t) threads, count * sizeof(thread_t));
    mach_port_deallocate(mach_task_self(), self);
    NSLog(@"nori: %s %s (kr=%d)", name, kr == KERN_SUCCESS ? "hooked" : "not hooked", kr);
}

__attribute__((constructor))
static void nori_payload_init(void)
{
    static char path[256];
    snprintf(path, sizeof(path), "/tmp/nori_%s.socket", getenv("USER") ?: "user");
    snprintf(control_path, sizeof(control_path), "/tmp/nori-ctl_%s.socket", getenv("USER") ?: "user");
    notify_queue = dispatch_queue_create("nori.notify", DISPATCH_QUEUE_SERIAL);
    queue = dispatch_queue_create("nori.anim", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    hook("SLSTransactionSetSpaceTransform", nori_transform_prologue, nori_transform_stub, &nori_transform_resume);
    hook("SLSTransactionSetSpaceShape", nori_shape_prologue, nori_shape_stub, &nori_shape_resume);
    hook("SLSTransactionSetManagedDisplayCurrentSpace", nori_current_prologue, nori_current_stub, &nori_current_resume);
    hook("SLSTransactionHideSpace", nori_hide_prologue, nori_hide_stub, &nori_hide_resume);
    CVDisplayLinkCreateWithActiveCGDisplays(&display_link);
    CVDisplayLinkSetOutputCallback(display_link, on_frame, NULL);
    CVDisplayLinkStart(display_link);
    pthread_t thread;
    pthread_create(&thread, NULL, serve, path);
    pthread_detach(thread);
}
