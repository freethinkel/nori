// make test: the payload's socket reader (payload/lines.h) and its ease (payload/glide.h).

#include <assert.h>
#include <stdio.h>
#include "../payload/glide.h"
#include "../payload/lines.h"

static char got[4][32];
static int count;

static void keep(char *line) { strcpy(got[count++], line); }

// Frames until x is within half a point of 0 and at rest, from 1000 at rest, at hz; never past 0 on the way.
static int settle(double hz)
{
    double x = 1000, v = 0;
    int frames = 0;
    while (fabs(x) >= 0.5 || fabs(v / hz) >= 0.5) {
        glide(&x, &v, 0, 1 / hz);
        assert(x > -0.5);
        frames++;
    }
    return frames;
}

int main(void)
{
    // A line cut between two reads comes out whole, once.
    char buf[64] = "E 5 1 0.";
    size_t have = take_lines(buf, strlen(buf), keep);
    assert(count == 0 && have == 8);
    memcpy(buf + have, "75\n\nA 7 1\nM", 11);
    have = take_lines(buf, have + 11, keep);
    assert(count == 2 && !strcmp(got[0], "E 5 1 0.75") && !strcmp(got[1], "A 7 1"));
    assert(have == 1 && buf[0] == 'M');

    // The same time at 60 and 120 Hz, about 0.35 s; the first frame moves a little, not a quarter of the way.
    double at60 = settle(60) / 60.0, at120 = settle(120) / 120.0;
    assert(at60 > 0.3 && at60 < 0.4 && fabs(at60 - at120) < 1.0 / 60);
    double x = 1000, v = 0;
    glide(&x, &v, 0, 1 / 60.0);
    assert(x > 900 && x < 950);
    // A new goal mid-way keeps the speed.
    double before = v;
    glide(&x, &v, 500, 0);
    assert(v == before);

    puts("payload: ok");
}
