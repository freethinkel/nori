// make test: the payload's socket reader (payload/lines.h). A line cut between two reads comes out whole, once.

#include <assert.h>
#include <stdio.h>
#include "../payload/lines.h"

static char got[4][32];
static int count;

static void keep(char *line) { strcpy(got[count++], line); }

int main(void)
{
    char buf[64] = "E 5 1 0.";
    size_t have = take_lines(buf, strlen(buf), keep);
    assert(count == 0 && have == 8);

    memcpy(buf + have, "75\n\nA 7 1\nM", 11);
    have = take_lines(buf, have + 11, keep);
    assert(count == 2 && !strcmp(got[0], "E 5 1 0.75") && !strcmp(got[1], "A 7 1"));
    assert(have == 1 && buf[0] == 'M');

    puts("payload lines: ok");
}
