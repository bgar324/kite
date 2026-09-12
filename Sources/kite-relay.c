/* Per-pane v2 transport. Terminal bytes exist only in bounded memory queues. */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/ioctl.h>
#include <arpa/inet.h>
#include <termios.h>
#include <poll.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define HEADER 16u
#define PAYLOAD 65536u
#define QUEUE_CAP (256u * 1024u)
#define SNAPSHOT_CAP (16u * 1024u * 1024u)
#define VERSION 2

enum message { ATTACH = 4, INPUT = 5, RESIZE = 6, OUTPUT = 7, EXIT = 8,
    READY = 9, ERROR = 10, REPLAY_START = 11, REPLAY_END = 12 };
enum phase { WAIT_REPLAY, REPLAYING, WAIT_READY, DRAIN_REPLAY, LIVE, FINISHED };
struct queue { unsigned char bytes[QUEUE_CAP]; size_t first, end; };
struct decoder { unsigned char bytes[HEADER + PAYLOAD]; size_t used, need; };
static volatile sig_atomic_t interrupted, resized;
static struct termios saved_termios;
static int terminal_saved, saved_in_flags = -1, saved_out_flags = -1;
static int signal_pipe[2] = { -1, -1 };

static int64_t milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) abort();
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
static void limit_timeout(int *timeout, int64_t deadline) {
    if (!deadline) return;
    int64_t remaining = deadline - milliseconds();
    int value = remaining <= 0 ? 0 : remaining > INT_MAX ? INT_MAX : (int)remaining;
    if (*timeout < 0 || value < *timeout) *timeout = value;
}
static int descriptor_flags(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    return fcntl(fd, F_SETFD, FD_CLOEXEC);
}
static void on_signal(int number) {
    int saved = errno;
    if (number == SIGWINCH) resized = 1;
    else interrupted = number;
    unsigned char byte = 1;
    (void)write(signal_pipe[1], &byte, 1);
    errno = saved;
}
static int install_signals(void) {
    if (pipe(signal_pipe) < 0 || descriptor_flags(signal_pipe[0]) < 0 ||
        descriptor_flags(signal_pipe[1]) < 0) return -1;
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    int signals[] = { SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGWINCH };
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i)
        if (sigaction(signals[i], &action, NULL) < 0) return -1;
    action.sa_handler = SIG_IGN;
    return sigaction(SIGPIPE, &action, NULL);
}
static void restore_terminal(void) {
    if (terminal_saved) {
        int result;
        do { result = tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios); } while (result < 0 && errno == EINTR);
        terminal_saved = 0;
    }
    if (saved_out_flags >= 0) fcntl(STDOUT_FILENO, F_SETFL, saved_out_flags);
    if (saved_in_flags >= 0) fcntl(STDIN_FILENO, F_SETFL, saved_in_flags);
    saved_in_flags = saved_out_flags = -1;
}
static int raw_terminal(void) {
    if (tcgetattr(STDIN_FILENO, &saved_termios) < 0) return -1;
    saved_in_flags = fcntl(STDIN_FILENO, F_GETFL);
    saved_out_flags = fcntl(STDOUT_FILENO, F_GETFL);
    if (saved_in_flags < 0 || saved_out_flags < 0) return -1;
    struct termios raw = saved_termios;
    cfmakeraw(&raw);
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) < 0) return -1;
    terminal_saved = 1;
    if (fcntl(STDIN_FILENO, F_SETFL, saved_in_flags | O_NONBLOCK) < 0 ||
        fcntl(STDOUT_FILENO, F_SETFL, saved_out_flags | O_NONBLOCK) < 0) return -1;
    return 0;
}
static size_t queued(const struct queue *q) { return q->end - q->first; }
static int append(struct queue *q, const void *bytes, size_t count) {
    if (count > QUEUE_CAP - queued(q)) return -1;
    if (count > QUEUE_CAP - q->end) {
        memmove(q->bytes, q->bytes + q->first, queued(q));
        q->end -= q->first;
        q->first = 0;
    }
    if (count) memcpy(q->bytes + q->end, bytes, count);
    q->end += count;
    return 0;
}
/* Return bytes written, zero for would-block, or -1 for failure. */
static ssize_t flush(int fd, struct queue *q) {
    if (!queued(q)) return 0;
    ssize_t count = write(fd, q->bytes + q->first, queued(q));
    if (count > 0) {
        q->first += (size_t)count;
        if (q->first == q->end) q->first = q->end = 0;
        return count;
    }
    if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    return -1;
}
static uint32_t decode32(const unsigned char *bytes) {
    uint32_t value;
    memcpy(&value, bytes, sizeof(value));
    return ntohl(value);
}
static int frame(struct queue *q, unsigned char kind, uint32_t pane, const void *bytes, size_t count) {
    if (count > PAYLOAD || HEADER + count > QUEUE_CAP - queued(q)) return -1;
    unsigned char header[HEADER] = { 'K', 'I', 'T', 'E', VERSION, kind, 0, 0 };
    uint32_t length = htonl((uint32_t)count), stream = htonl(pane);
    memcpy(header + 8, &length, 4);
    memcpy(header + 12, &stream, 4);
    if (append(q, header, sizeof(header)) < 0) return -1;
    return append(q, bytes, count);
}
/* Consume no bytes from the next frame, even when the socket coalesces frames. */
static int receive_frame(int fd, struct decoder *d, uint32_t pane) {
    if (!d->need) d->need = HEADER;
    ssize_t count = read(fd, d->bytes + d->used, d->need - d->used);
    if (count == 0) return -1;
    if (count < 0) {
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        return -1;
    }
    d->used += (size_t)count;
    if (d->used < d->need) return 0;
    if (d->need == HEADER) {
        if (memcmp(d->bytes, "KITE", 4) || d->bytes[4] != VERSION || d->bytes[6] || d->bytes[7] ||
            decode32(d->bytes + 8) > PAYLOAD || decode32(d->bytes + 12) != pane) return -2;
        d->need += decode32(d->bytes + 8);
        if (d->used < d->need) return 0;
    }
    return 1;
}
static int connect_endpoint(const char *path) {
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    if (strlen(path) >= sizeof(address.sun_path)) { errno = ENAMETOOLONG; return -1; }
    address.sun_family = AF_UNIX;
    address.sun_len = (unsigned char)sizeof(address);
    strcpy(address.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (descriptor_flags(fd) < 0) goto failed;
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        if (errno != EINPROGRESS && errno != EAGAIN) goto failed;
        int64_t deadline = milliseconds() + 3000;
        for (;;) {
            if (interrupted) { errno = EINTR; goto failed; }
            int timeout = -1;
            limit_timeout(&timeout, deadline);
            struct pollfd fds[2] = { { fd, POLLOUT, 0 }, { signal_pipe[0], POLLIN, 0 } };
            int result = poll(fds, 2, timeout);
            if (result < 0 && errno == EINTR) continue;
            if (result < 0) goto failed;
            if (milliseconds() >= deadline) { errno = ETIMEDOUT; goto failed; }
            if (fds[1].revents) {
                unsigned char bytes[128];
                while (read(signal_pipe[0], bytes, sizeof(bytes)) > 0) {}
            }
            if (!fds[0].revents) continue;
            int error = 0;
            socklen_t length = sizeof(error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) < 0) goto failed;
            if (error) { errno = error; goto failed; }
            break;
        }
    }
    uid_t uid;
    gid_t gid;
    if (getpeereid(fd, &uid, &gid) < 0) goto failed;
    if (uid != getuid()) { errno = EACCES; goto failed; }
    return fd;
failed: {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
}
}
static int dimensions(struct queue *tx, unsigned char kind, uint32_t pane) {
    struct winsize size;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &size) < 0) return -1;
    if (!size.ws_row || !size.ws_col || size.ws_row > 1000 || size.ws_col > 1000) { errno = EINVAL; return -1; }
    uint16_t values[4] = { htons(size.ws_row), htons(size.ws_col), htons(size.ws_xpixel), htons(size.ws_ypixel) };
    return frame(tx, kind, pane, values, sizeof(values));
}
static int relay(const char *path, uint32_t pane) {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        fprintf(stderr, "kite-relay: attach requires terminal stdin and stdout\n"); return 2;
    }
    int fd = -1, code = 1;
    struct queue *tx = calloc(1, sizeof(*tx)), *output = calloc(1, sizeof(*output));
    struct decoder rx = { { 0 }, 0, 0 };
    enum phase phase = WAIT_REPLAY;
    size_t snapshot_bytes = 0;
    char error[512] = "";
    int64_t handshake_deadline = milliseconds() + 30000, drain_deadline = 0;
    int64_t output_deadline = 0, input_deadline = 0;
    if (!tx || !output) { snprintf(error, sizeof(error), "allocating transport buffers failed"); goto done; }
    // Raw before replay prevents echo, newline translation, and local signal handling.
    if (raw_terminal() < 0) { snprintf(error, sizeof(error), "setting raw terminal: %s", strerror(errno)); goto done; }
    fd = connect_endpoint(path);
    if (fd < 0) { snprintf(error, sizeof(error), "connecting to daemon: %s", strerror(errno)); goto done; }
    if (dimensions(tx, ATTACH, pane) < 0) { snprintf(error, sizeof(error), "reading terminal dimensions: %s", strerror(errno)); goto done; }
    for (;;) {
        unsigned char signals[128];
        while (read(signal_pipe[0], signals, sizeof(signals)) > 0) {}
        if (interrupted) { code = 128 + interrupted; break; }
        if (phase == FINISHED && !queued(output)) break;
        int64_t now = milliseconds();
        if ((handshake_deadline && now >= handshake_deadline) || (drain_deadline && now >= drain_deadline) ||
            (output_deadline && now >= output_deadline) || (input_deadline && now >= input_deadline)) {
            snprintf(error, sizeof(error), "%s", phase == FINISHED ? "terminal output drain timed out" :
                handshake_deadline ? "daemon snapshot handshake timed out" : "terminal transport stalled");
            code = 1; break;
        }
        if (phase == DRAIN_REPLAY && !queued(output)) {
            // Discard pre-READY keystrokes, including bytes buffered by the outer PTY.
            if (tcflush(STDIN_FILENO, TCIFLUSH) < 0 || frame(tx, READY, pane, NULL, 0) < 0) {
                snprintf(error, sizeof(error), "acknowledging snapshot readiness failed"); goto finish;
            }
            phase = LIVE;
            handshake_deadline = 0;
            resized = 1;
        }
        if (phase == LIVE && resized && QUEUE_CAP - queued(tx) >= HEADER + 8) {
            resized = 0;
            if (dimensions(tx, RESIZE, pane) < 0) {
                snprintf(error, sizeof(error), "reading terminal dimensions: %s", strerror(errno)); goto finish;
            }
        }
        if (queued(output) && !output_deadline) output_deadline = now + 10000;
        if (queued(tx) && !input_deadline) input_deadline = now + 10000;
        int can_receive = phase != FINISHED && phase != DRAIN_REPLAY && QUEUE_CAP - queued(output) >= PAYLOAD;
        struct pollfd fds[4] = {
            { can_receive || queued(tx) ? fd : -1, (short)((can_receive ? POLLIN : 0) | (queued(tx) ? POLLOUT : 0)), 0 },
            { phase == FINISHED ? -1 : STDIN_FILENO, (short)((phase != LIVE || QUEUE_CAP - queued(tx) >= HEADER + 8192) ? POLLIN : 0), 0 },
            { queued(output) ? STDOUT_FILENO : -1, POLLOUT, 0 },
            { signal_pipe[0], POLLIN, 0 }
        };
        int timeout = -1;
        limit_timeout(&timeout, handshake_deadline);
        limit_timeout(&timeout, drain_deadline);
        limit_timeout(&timeout, output_deadline);
        limit_timeout(&timeout, input_deadline);
        int result = poll(fds, 4, timeout);
        if (result < 0) {
            if (errno == EINTR) continue;
            snprintf(error, sizeof(error), "poll: %s", strerror(errno)); goto finish;
        }
        if (fds[2].revents & (POLLOUT | POLLERR | POLLHUP | POLLNVAL)) {
            ssize_t count = flush(STDOUT_FILENO, output);
            if (count < 0) { snprintf(error, sizeof(error), "writing terminal: %s", strerror(errno)); break; }
            if (count > 0) output_deadline = queued(output) ? milliseconds() + 10000 : 0;
        }
        if (fds[0].revents & POLLOUT) {
            ssize_t count = flush(fd, tx);
            if (count < 0) { snprintf(error, sizeof(error), "daemon disconnected while sending input"); goto finish; }
            if (count > 0) input_deadline = queued(tx) ? milliseconds() + 10000 : 0;
        }
        if (can_receive && (fds[0].revents & (POLLIN | POLLHUP | POLLERR))) {
            result = receive_frame(fd, &rx, pane);
            if (result < 0) {
                snprintf(error, sizeof(error), "%s", result == -2 ? "invalid daemon protocol" : "daemon disconnected without an exit status");
                goto finish;
            }
            if (result == 1) {
                unsigned char kind = rx.bytes[5], *bytes = rx.bytes + HEADER;
                size_t length = rx.need - HEADER;
                if (kind == ERROR) {
                    size_t n = length < sizeof(error) - 1 ? length : sizeof(error) - 1;
                    for (size_t i = 0; i < n; ++i) error[i] = bytes[i] >= 32 && bytes[i] < 127 ? (char)bytes[i] : '?';
                    error[n] = '\0';
                    if (!n) strcpy(error, "daemon rejected pane attachment");
                    goto finish;
                } else if (kind == REPLAY_START && phase == WAIT_REPLAY && !length) {
                    phase = REPLAYING;
                } else if (kind == REPLAY_END && phase == REPLAYING && !length) {
                    phase = WAIT_READY;
                } else if (kind == READY && phase == WAIT_READY && !length) {
                    phase = DRAIN_REPLAY;
                } else if (kind == OUTPUT && (phase == REPLAYING || phase == LIVE) && length) {
                    if (phase == REPLAYING) {
                        if (length > SNAPSHOT_CAP - snapshot_bytes) { strcpy(error, "daemon snapshot exceeds 16 MiB"); goto finish; }
                        snapshot_bytes += length;
                    }
                    if (append(output, bytes, length) < 0) { strcpy(error, "terminal output queue is full"); goto finish; }
                } else if (kind == EXIT && phase == LIVE && length == 4 && decode32(bytes) <= 255) {
                    code = (int)decode32(bytes);
                    goto finish;
                } else { strcpy(error, "unexpected daemon response for pane state"); goto finish; }
                rx.used = rx.need = 0;
            }
        }
        if (fds[0].revents & POLLNVAL) { strcpy(error, "daemon socket closed"); goto finish; }
        if (phase != FINISHED && (fds[1].revents & (POLLIN | POLLHUP))) {
            unsigned char bytes[8192];
            ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
            if (count > 0 && phase == LIVE) {
                if (frame(tx, INPUT, pane, bytes, (size_t)count) < 0) { strcpy(error, "terminal input queue is full"); goto finish; }
            } else if (!count) { code = 0; goto finish; }
            else if (count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                snprintf(error, sizeof(error), "reading terminal: %s", strerror(errno)); goto finish;
            }
        }
        if (fds[1].revents & (POLLERR | POLLNVAL)) { strcpy(error, "input terminal closed"); goto finish; }
        continue;
finish:
        if (error[0]) code = 1;
        phase = FINISHED;
        handshake_deadline = input_deadline = 0;
        drain_deadline = milliseconds() + 10000;
        tx->first = tx->end = 0;
    }
done:
    restore_terminal();
    if (fd >= 0) close(fd);
    free(tx);
    free(output);
    if (interrupted) return 128 + interrupted;
    if (error[0]) { fprintf(stderr, "kite-relay: %s\n", error); return 1; }
    return code;
}
int main(int argc, char **argv) {
    if (argc != 4 || strcmp(argv[1], "attach")) {
        fprintf(stderr, "usage: kite-relay attach SOCKET PANE_ID\n"); return 2;
    }
    char *end = NULL;
    errno = 0;
    unsigned long pane = strtoul(argv[3], &end, 10);
    if (errno || !argv[3][0] || argv[3][0] < '0' || argv[3][0] > '9' || !end || *end || !pane || pane > UINT32_MAX) {
        fprintf(stderr, "kite-relay: PANE_ID must be a nonzero UInt32\n"); return 2;
    }
    if (install_signals() < 0) { perror("kite-relay: installing signal handlers"); return 1; }
    if (atexit(restore_terminal) != 0) { fprintf(stderr, "kite-relay: registering terminal cleanup failed\n"); return 1; }
    int result = relay(argv[2], (uint32_t)pane);
    close(signal_pipe[0]);
    close(signal_pipe[1]);
    return result;
}
