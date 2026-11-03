// Lines out of a stream socket (serve in payload.m): a read can end mid-line, and that line waits for its rest.
// Hands each complete line of buf[0..len) to handle, skips empty ones, moves the unfinished rest to the front of buf
// and returns its length. Checked by test/lines.c.

#include <string.h>

static size_t take_lines(char *buf, size_t len, void (*handle)(char *line))
{
    char *start = buf, *end = buf + len, *nl;
    while ((nl = (char *) memchr(start, '\n', end - start))) {
        *nl = '\0';
        if (nl > start) handle(start);
        start = nl + 1;
    }
    memmove(buf, start, end - start);
    return end - start;
}
