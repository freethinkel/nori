// POC, not part of nori: does Dock run its interactive Space swipe from synthetic DockSwipe events on macOS 27?
// clang -framework ApplicationServices probe/dock-swipe.m -o build/dock-swipe && build/dock-swipe <dir 1|-1> <hold> <commit 0|1>
// Began, Changed from 0 to `hold` over 0.4 s, a pause, then Ended with a fling (commit 1) or without (0), or Cancelled (2).
// The event layout and the IOHID payload macOS 27 wants are from InstantSpaceSwitcher (MIT, (c) 2026 jurplel),
// Sources/ISS/ISS.c and event_serialize.c.
#include <ApplicationServices/ApplicationServices.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int CGSMainConnectionID(void);
extern uint64_t CGSGetActiveSpace(int cid);

#pragma pack(push, 1)
typedef struct { uint32_t size, type, options; uint8_t depth, reserved[3]; } base_t;
typedef struct { base_t base; int32_t x, y, z; uint32_t mask; uint16_t motion, flavor; int32_t progress; } fluid_t;
typedef struct { base_t base; int32_t x, y, z; } velocity_t;
typedef struct { uint64_t timestamp, sender; uint32_t options, attributes, count; } header_t;
#pragma pack(pop)

static int32_t fixed(double v) { int32_t f = (int32_t)(v * 65536.0); return f == 0 && v != 0 ? (v > 0 ? 1 : -1) : f; }

static void post(int phase, double progress, double velocity) {
    CGEventRef e = CGEventCreate(NULL);
    CGEventSetIntegerValueField(e, 55, 30);   // DockControl
    CGEventSetIntegerValueField(e, 110, 23);  // DockSwipe
    CGEventSetIntegerValueField(e, 132, phase);
    CGEventSetIntegerValueField(e, 123, 1);   // horizontal
    CGEventSetDoubleValueField(e, 124, progress);
    CGEventSetIntegerValueField(e, 134, phase);
    CGEventSetDoubleValueField(e, 138, 3.0);
    CGEventSetDoubleValueField(e, 169, (double)mach_absolute_time());
    CGEventSetDoubleValueField(e, 125, 0.1);
    if (phase == 4) CGEventSetDoubleValueField(e, 129, velocity);

    bool with_velocity = phase == 4;
    size_t n = sizeof(header_t) + sizeof(fluid_t) + (with_velocity ? sizeof(velocity_t) : 0);
    uint8_t *p = calloc(1, n);
    header_t *h = (header_t *)p;
    h->timestamp = mach_absolute_time();
    h->count = with_velocity ? 2 : 1;
    fluid_t *f = (fluid_t *)(p + sizeof(header_t));
    f->base.size = sizeof(fluid_t); f->base.type = 23; f->base.options = (uint32_t)(phase & 0xFF) << 24;
    f->x = fixed(0.1); f->motion = 1; f->flavor = 3; f->progress = fixed(progress);
    if (with_velocity) {
        velocity_t *v = (velocity_t *)(p + sizeof(header_t) + sizeof(fluid_t));
        v->base.size = sizeof(velocity_t); v->base.type = 9; v->base.depth = 1; v->x = fixed(velocity);
    }
    CFDataRef data = CGEventCreateData(NULL, e);
    CFIndex len = CFDataGetLength(data);
    CFMutableDataRef out = CFDataCreateMutableCopy(NULL, 0, data);
    uint8_t tag[4] = { (uint8_t)(n >> 8), (uint8_t)n, 4205 >> 8, 4205 & 0xFF };
    CFDataAppendBytes(out, tag, 4);
    CFDataAppendBytes(out, p, (CFIndex)n);
    (void)len;
    CGEventRef a = CGEventCreateFromData(NULL, out);
    CGEventRef g = CGEventCreate(NULL);
    CGEventSetIntegerValueField(g, 55, 29);
    CGEventPost(kCGSessionEventTap, a);
    CGEventPost(kCGSessionEventTap, g);
    CFRelease(a); CFRelease(g); CFRelease(out); CFRelease(data); CFRelease(e); free(p);
}

int main(int argc, char **argv) {
    double dir = argc > 1 ? atof(argv[1]) : 1, hold = argc > 2 ? atof(argv[2]) : 0.5;
    int commit = argc > 3 ? atoi(argv[3]) : 1;
    int cid = CGSMainConnectionID();
    printf("before %llu\n", CGSGetActiveSpace(cid));
    post(1, 0, 0);
    for (int i = 1; i <= 24; i++) { usleep(16000); post(2, dir * hold * i / 24, 0); }
    usleep(400000);
    if (commit == 2) post(8, dir * hold, 0); else post(4, dir * hold, commit ? dir * 9999 : 0);
    usleep(900000);
    printf("after %llu\n", CGSGetActiveSpace(cid));
}
