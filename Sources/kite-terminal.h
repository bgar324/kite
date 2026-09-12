#ifndef KITE_TERMINAL_H
#define KITE_TERMINAL_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct KiteTerminal KiteTerminal;
/* Serial-queue confined. No Ghostty app, renderer, or global allocator required.
 * Dimensions: 1..1000. Scrollback: at most 2 MiB, plus Ghostty's active-grid
 * minimum. A false feed/resize is a fatal state failure; do not publish a
 * snapshot as authoritative after it. Free and restart the pane explicitly.
 */
KiteTerminal *kite_terminal_new(uint16_t cols, uint16_t rows, size_t scrollbackBytes);
void kite_terminal_free(KiteTerminal *terminal);
bool kite_terminal_feed(KiteTerminal *terminal, const uint8_t *bytes, size_t len);
bool kite_terminal_resize(KiteTerminal *terminal, uint16_t cols, uint16_t rows);
/* Safe reconstructed VT, never historical output. Both screens and retained
 * history are included. Maximum 16 MiB. On failure outputs are NULL/0.
 * An unfinished VT/UTF-8 prefix is appended LAST, so the next live byte resumes
 * it. No waiting for parser ground is necessary. Never insert terminal bytes
 * between this snapshot and subsequent PTY output. Snapshot creation, resize,
 * relay installation, and output queuing must be atomic on the daemon queue.
 * An incomplete sequence exceeding 64 KiB makes snapshots unavailable until
 * the parser reaches ground; it never terminates the shell or poisons feed.
 */
bool kite_terminal_snapshot(KiteTerminal *terminal, uint8_t **bytes, size_t *len);
void kite_terminal_bytes_free(uint8_t *bytes, size_t len);
/* Borrowed NUL-terminated UTF-8, valid until next feed/free. cwd is a decoded
 * absolute local path from OSC 7, not a file URL. Empty means not yet reported.
 */
const char *kite_terminal_title(KiteTerminal *terminal);
const char *kite_terminal_cwd(KiteTerminal *terminal);
bool kite_terminal_in_ground(KiteTerminal *terminal);
/* Drain after EVERY feed, even while attached. Write replies into the shell
 * PTY only when no relay controls the pane; otherwise DISCARD them because
 * the attached Ghostty surface answers the same queries. Drain before changing
 * ownership. true + NULL/0 is an empty queue; false is an allocation/state
 * failure. Reply queue is bounded to 64 KiB; excess queries are dropped rather
 * than failing terminal state. Invalid title/cwd metadata is ignored.
 * Never forward replies to GUI.
 * Detached clipboard reads return empty; writes/notifications are not replayed.
 */
bool kite_terminal_take_reply(KiteTerminal *terminal, uint8_t **bytes, size_t *len);
#ifdef __cplusplus
}
#endif
#endif
