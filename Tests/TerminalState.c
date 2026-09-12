#include "../Sources/kite-terminal.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int contains(const uint8_t *bytes, size_t length, const char *needle) {
    size_t size = strlen(needle);
    for (size_t i = 0; size <= length && i <= length - size; ++i)
        if (!memcmp(bytes + i, needle, size)) return 1;
    return 0;
}
static void feed(KiteTerminal *terminal, const char *text) {
    assert(kite_terminal_feed(terminal, (const uint8_t *)text, strlen(text)));
}
static KiteTerminal *restore(KiteTerminal *source, uint16_t cols, uint16_t rows) {
    uint8_t *bytes = NULL;
    size_t length = 0;
    assert(kite_terminal_snapshot(source, &bytes, &length));
    KiteTerminal *copy = kite_terminal_new(cols, rows, 4096);
    assert(copy && kite_terminal_feed(copy, bytes, length));
    kite_terminal_bytes_free(bytes, length);
    return copy;
}
static void cursor(KiteTerminal *terminal, const char *expected) {
    uint8_t *bytes = NULL;
    size_t length = 0;
    feed(terminal, "\033[6n");
    assert(kite_terminal_take_reply(terminal, &bytes, &length));
    assert(length == strlen(expected) && !memcmp(bytes, expected, length));
    kite_terminal_bytes_free(bytes, length);
}
static void same_snapshot(KiteTerminal *first, KiteTerminal *second) {
    /* Normalize implicit versus explicitly designated default charsets through
     * the VT wire representation before comparing these 8x3 test screens. */
    KiteTerminal *normalized_first = restore(first, 8, 3);
    KiteTerminal *normalized_second = restore(second, 8, 3);
    uint8_t *a = NULL, *b = NULL;
    size_t a_len = 0, b_len = 0;
    assert(kite_terminal_snapshot(normalized_first, &a, &a_len));
    assert(kite_terminal_snapshot(normalized_second, &b, &b_len));
    assert(a_len == b_len && !memcmp(a, b, a_len));
    kite_terminal_bytes_free(a, a_len);
    kite_terminal_bytes_free(b, b_len);
    kite_terminal_free(normalized_first);
    kite_terminal_free(normalized_second);
}
static void restoration_contracts(void) {
    uint8_t *bytes = NULL;
    size_t length = 0;
    KiteTerminal *original = kite_terminal_new(4, 3, 4096);
    assert(original);
    feed(original, "abc界Z");
    KiteTerminal *copy = restore(original, 4, 3);
    assert(kite_terminal_snapshot(copy, &bytes, &length));
    size_t wide_count = 0;
    for (size_t i = 0; i + strlen("界") <= length; ++i)
        if (!memcmp(bytes + i, "界", strlen("界"))) ++wide_count;
    assert(wide_count == 1);
    kite_terminal_bytes_free(bytes, length);
    cursor(copy, "\033[2;4R");
    kite_terminal_free(original);
    kite_terminal_free(copy);

    original = kite_terminal_new(8, 3, 4096);
    assert(original);
    feed(original, "\033[1\"qA\033[0\"qB");
    copy = restore(original, 8, 3);
    feed(original, "\033[?2K");
    feed(copy, "\033[?2K");
    same_snapshot(original, copy);
    kite_terminal_free(original);
    kite_terminal_free(copy);

    /* ISO protection also survives ordinary ECH, unlike DECSCA protection. */
    original = kite_terminal_new(8, 3, 4096);
    assert(original);
    feed(original, "\033VA\033WB\033[H");
    copy = restore(original, 8, 3);
    feed(original, "\033[2X");
    feed(copy, "\033[2X");
    same_snapshot(original, copy);
    kite_terminal_free(original);
    kite_terminal_free(copy);

    original = kite_terminal_new(8, 3, 4096);
    assert(original);
    feed(original, "A");
    copy = restore(original, 8, 3);
    feed(original, "\033[3b");
    feed(copy, "\033[3b");
    cursor(original, "\033[1;5R");
    cursor(copy, "\033[1;5R");
    assert(kite_terminal_snapshot(copy, &bytes, &length));
    assert(contains(bytes, length, "AAAA"));
    kite_terminal_bytes_free(bytes, length);
    kite_terminal_free(original);
    kite_terminal_free(copy);

    /* REP must work even when its previous glyph has since been erased. */
    original = kite_terminal_new(8, 3, 4096);
    assert(original);
    feed(original, "A\033[H\033[X");
    copy = restore(original, 8, 3);
    feed(original, "\033[3b");
    feed(copy, "\033[3b");
    same_snapshot(original, copy);
    cursor(copy, "\033[1;4R");
    kite_terminal_free(original);
    kite_terminal_free(copy);

    /* Never manufacture a previous space while restoring an empty terminal. */
    original = kite_terminal_new(8, 3, 4096);
    assert(original);
    copy = restore(original, 8, 3);
    feed(copy, "\033[3b");
    cursor(copy, "\033[1;1R");
    kite_terminal_free(original);
    kite_terminal_free(copy);

    /* A blank wrapped continuation must not erase the preceding row's tail. */
    original = kite_terminal_new(4, 3, 4096);
    assert(original);
    feed(original, "ABCDE\033[2K");
    copy = restore(original, 4, 3);
    assert(kite_terminal_snapshot(copy, &bytes, &length));
    assert(contains(bytes, length, "ABCD"));
    kite_terminal_bytes_free(bytes, length);
    kite_terminal_free(original);
    kite_terminal_free(copy);

    original = kite_terminal_new(8, 4, 4096);
    assert(original);
    feed(original, "\033[1\n");
    copy = restore(original, 8, 4);
    feed(original, "mX");
    feed(copy, "mX");
    cursor(original, "\033[2;2R");
    cursor(copy, "\033[2;2R");
    kite_terminal_free(original);
    kite_terminal_free(copy);
}
int main(void) {
    restoration_contracts();
    KiteTerminal *first = kite_terminal_new(80, 24, 2 * 1024 * 1024);
    assert(first);
    feed(first, "\033[31mPRIMARY_RED\033[0m\r\nnormal\033]52;c;c2VjcmV0\007\033[6n");
    feed(first, "\033[?1049h\033[2J\033[4;7HALTERNATE\033[?2004h");
    uint8_t *snapshot = NULL;
    size_t length = 0;
    assert(kite_terminal_snapshot(first, &snapshot, &length));
    assert(length > 0 && length <= 16 * 1024 * 1024);
    assert(contains(snapshot, length, "PRIMARY_RED") && contains(snapshot, length, "ALTERNATE"));
    assert(!contains(snapshot, length, "]52;") && !contains(snapshot, length, "[6n"));
    KiteTerminal *second = kite_terminal_new(80, 24, 2 * 1024 * 1024);
    assert(second && kite_terminal_feed(second, snapshot, length));
    kite_terminal_bytes_free(snapshot, length);
    feed(second, "\033[?1049l\r\nAFTER_RECONNECT");
    assert(kite_terminal_snapshot(second, &snapshot, &length));
    assert(contains(snapshot, length, "PRIMARY_RED") && contains(snapshot, length, "AFTER_RECONNECT"));
    kite_terminal_bytes_free(snapshot, length);
    kite_terminal_free(first);
    kite_terminal_free(second);

    /* Reconnect in the middle of UTF-8 must carry its undecoded prefix once. */
    first = kite_terminal_new(80, 24, 4096);
    second = kite_terminal_new(80, 24, 4096);
    assert(first && second);
    assert(kite_terminal_feed(first, (const uint8_t *)"snow \xe2\x98", 7));
    assert(kite_terminal_snapshot(first, &snapshot, &length));
    assert(kite_terminal_feed(second, snapshot, length));
    kite_terminal_bytes_free(snapshot, length);
    assert(kite_terminal_feed(second, (const uint8_t *)"\x83", 1));
    assert(kite_terminal_snapshot(second, &snapshot, &length));
    assert(contains(snapshot, length, "snow \xe2\x98\x83"));
    kite_terminal_bytes_free(snapshot, length);
    kite_terminal_free(first);
    kite_terminal_free(second);
    puts("Canonical primary/alternate state, side-effect exclusion, and partial UTF-8 restore passed");
    return 0;
}
