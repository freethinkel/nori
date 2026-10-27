// niri-mac payload: loaded into Dock.app by loader. Serves a line protocol on a unix socket.
// Lines: "S wid x y"         set target; payload eases the window there
//        "T wid a b c d tx ty"  transform
//        "M wid x y"           move (immediate)
//        "A wid alpha"         alpha
//        "O wid order rel"     order
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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
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

#define MAX_ANIMS 128

typedef struct {
    uint32_t wid;
    CGPoint cur;
    CGPoint goal;
} anim_t;

static dispatch_queue_t queue;
static CVDisplayLinkRef display_link;
static anim_t anims[MAX_ANIMS];
static int anim_count;

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

static void tick(void)
{
    if (!anim_count) return;
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
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}

static CVReturn on_frame(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *out, CVOptionFlags in, CVOptionFlags *flags, void *ctx)
{
    dispatch_sync(queue, ^{ tick(); });
    return kCVReturnSuccess;
}

static void handle_line(char *line)
{
    int cid = SLSMainConnectionID();
    uint32_t wid;
    switch (line[0]) {
    case 'S': {
        CGPoint goal;
        if (sscanf(line + 1, "%u %lf %lf", &wid, &goal.x, &goal.y) == 3) {
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
            anim_drop(wid);  // a running ease would pull the window back every frame
            SLSMoveWindowWithGroup(cid, wid, &p);
        }
        break;
    }
    case 'A': {
        float alpha;
        if (sscanf(line + 1, "%u %f", &wid, &alpha) == 2) {
            SLSSetWindowAlpha(cid, wid, alpha);
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

// Vertical Spaces. Dock slides spaces with SLSTransactionSetSpaceTransform(transaction, sid, u32, const CGAffineTransform *).
// Dock's __DATA_CONST (its import table) can't be made writable, so we patch the function's first 16 bytes
// in Dock's copy of SkyLight: "ldr x16, #8; br x16; <stub>". The stub swaps x3 for a vertical transform,
// runs the 4 displaced prologue instructions and jumps back to fn + 16.
// Works because Dock is CS_DEBUGGED after injection, so a modified code page doesn't kill it.
// ponytail: prologue is checked byte for byte; another macOS build with a different one keeps horizontal spaces.
// ponytail: main display aspect only; spaces on a display with another aspect slide the wrong distance.
__attribute__((visibility("hidden"))) void *niri_space_resume;
extern char niri_space_stub[], niri_space_prologue[];

// Pure horizontal translations (the slide) become vertical. Scaled ones (Mission Control) pass through.
__attribute__((visibility("hidden"), used))
const CGAffineTransform *niri_vertical_transform(const CGAffineTransform *t, uint64_t sid, uint32_t unknown)
{
    static __thread CGAffineTransform vertical;
    if (t) NSLog(@"niri-mac: space %llu u=%u [%g %g %g %g %g %g]", sid, unknown, t->a, t->b, t->c, t->d, t->tx, t->ty);  // DEBUG
    if (!t || t->a != 1 || t->b != 0 || t->c != 0 || t->d != 1 || t->tx == 0) return t;
    CGRect screen = CGDisplayBounds(CGMainDisplayID());
    vertical = *t;
    vertical.ty += t->tx * screen.size.height / screen.size.width;
    vertical.tx = 0;
    return &vertical;
}

__asm__(
    ".text\n"
    ".p2align 2\n"
    ".private_extern _niri_space_stub\n"
    "_niri_space_stub:\n"
    "    stp x29, x30, [sp, #-48]!\n"
    "    mov x29, sp\n"
    "    stp x0, x1, [sp, #16]\n"
    "    stp x2, x3, [sp, #32]\n"
    "    mov x0, x3\n"  // x1 (sid) and x2 are still the original args
    "    bl _niri_vertical_transform\n"
    "    mov x3, x0\n"
    "    ldp x0, x1, [sp, #16]\n"
    "    ldr x2, [sp, #32]\n"
    "    ldp x29, x30, [sp], #48\n"
    ".private_extern _niri_space_prologue\n"
    "_niri_space_prologue:\n"
    "    pacibsp\n"
    "    stp d9, d8, [sp, #-0x40]!\n"
    "    stp x22, x21, [sp, #0x10]\n"
    "    stp x20, x19, [sp, #0x20]\n"
    "    adrp x16, _niri_space_resume@PAGE\n"
    "    ldr x16, [x16, _niri_space_resume@PAGEOFF]\n"
    "    br x16\n"
);

static void hook_space_transform(void)
{
    uint8_t *fn = ptrauth_strip(dlsym(RTLD_DEFAULT, "SLSTransactionSetSpaceTransform"), ptrauth_key_asia);
    if (!fn || memcmp(fn, niri_space_prologue, 16) != 0) {
        NSLog(@"niri-mac: vertical spaces off: SLSTransactionSetSpaceTransform prologue differs");
        return;
    }
    niri_space_resume = fn + 16;
    uint32_t patch[4] = { 0x58000050, 0xd61f0200 };  // ldr x16, #8; br x16
    void *stub = niri_space_stub;
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
    NSLog(@"niri-mac: vertical spaces %s (kr=%d)", kr == KERN_SUCCESS ? "on" : "off", kr);
}

__attribute__((constructor))
static void niri_mac_payload_init(void)
{
    static char path[256];
    snprintf(path, sizeof(path), "/tmp/niri-mac_%s.socket", getenv("USER") ?: "user");
    queue = dispatch_queue_create("niri-mac.anim", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    hook_space_transform();
    CVDisplayLinkCreateWithActiveCGDisplays(&display_link);
    CVDisplayLinkSetOutputCallback(display_link, on_frame, NULL);
    CVDisplayLinkStart(display_link);
    pthread_t thread;
    pthread_create(&thread, NULL, serve, path);
    pthread_detach(thread);
}
