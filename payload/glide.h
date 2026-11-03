// Every ease in the payload (windows, fades, stretches, Space switches) is a critically damped spring, niri's default for
// window movement (stiffness 800, damping ratio 1), solved exactly over each frame's dt: the same curve at 60 and 120 Hz,
// no jump on the first frame, and a new goal mid-way keeps the speed. From rest, 90% of the way in 0.14 s, within half a
// point of 1000 in 0.35 s. Stiffer is snappier: 1600 makes those 0.10 s and 0.25 s. Checked by test/payload.c.

#include <math.h>

#define GLIDE_STIFFNESS 800.0

// x toward goal over dt seconds; v in x's units per second.
static void glide(double *x, double *v, double goal, double dt)
{
    double w = sqrt(GLIDE_STIFFNESS), e = exp(-w * dt), d = *x - goal, c = *v + w * d;
    *x = goal + (d + c * dt) * e;
    *v = (*v - w * c * dt) * e;
}
