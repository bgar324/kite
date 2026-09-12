#ifndef KITE_PTY_H
#define KITE_PTY_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
typedef struct KiteEndpoint KiteEndpoint;
typedef struct KiteProcessTree KiteProcessTree;
KiteEndpoint *kite_endpoint_open(const char *path);
int kite_endpoint_fd(KiteEndpoint *endpoint);
void kite_endpoint_close(KiteEndpoint *endpoint);
int kite_accept(int listener);
int kite_pty_spawn(const char *shell, const char *cwd, bool login, uint16_t rows, uint16_t cols, int32_t *pid);
int kite_pty_resize(int fd, uint16_t rows, uint16_t cols, uint16_t width, uint16_t height);
int kite_pty_cwd(int32_t pid, char *buffer, size_t capacity);
int kite_reap(int32_t pid, int32_t *code);
int kite_child_exited(int32_t pid);
KiteProcessTree *kite_process_tree_capture(int32_t pid);
void kite_process_tree_dispose(KiteProcessTree *tree);
void kite_process_tree_signal(KiteProcessTree *tree);
KiteProcessTree *kite_terminate_begin(int32_t pid);
void kite_terminate_finish(KiteProcessTree *tree);
#endif
