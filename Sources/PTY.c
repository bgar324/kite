#include "PTY.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/sysctl.h>
#include <libproc.h>
#include <util.h>
#include <termios.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;
struct KiteEndpoint { int directory, lock, listener; dev_t device; ino_t inode; char name[NAME_MAX + 1]; };
static int descriptor_flags(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) return -1;
    return 0;
}
void kite_endpoint_close(KiteEndpoint *e) {
    if (!e) return;
    int error = errno;
    if (e->listener >= 0) close(e->listener);
    struct stat st;
    if (e->inode && fstatat(e->directory, e->name, &st, AT_SYMLINK_NOFOLLOW) == 0 &&
        st.st_ino == e->inode && st.st_dev == e->device && S_ISSOCK(st.st_mode)) unlinkat(e->directory, e->name, 0);
    if (e->lock >= 0) close(e->lock);
    if (e->directory >= 0) close(e->directory);
    free(e);
    errno = error;
}
KiteEndpoint *kite_endpoint_open(const char *path) {
    KiteEndpoint *e = calloc(1, sizeof(*e));
    if (!e) return NULL;
    e->directory = e->lock = e->listener = -1;
    char parent[PATH_MAX], resolved[PATH_MAX];
    if (path[0] != '/' || strlen(path) >= sizeof(parent)) { errno = EINVAL; goto failed; }
    strcpy(parent, path);
    char *slash = strrchr(parent, '/');
    if (!slash || !slash[1] || strlen(slash + 1) > NAME_MAX || !strcmp(slash + 1, ".") || !strcmp(slash + 1, "..")) { errno = EINVAL; goto failed; }
    strcpy(e->name, slash + 1);
    if (slash == parent) slash[1] = 0; else *slash = 0;
    for (char *p = parent + 1; ; ++p) {
        if (*p && *p != '/') continue;
        char saved = *p; *p = 0;
        int result = mkdir(parent, 0700); *p = saved;
        if (result < 0 && errno != EEXIST) goto failed;
        if (!saved) break;
    }
    e->directory = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (e->directory < 0 || fstat(e->directory, &st) < 0) goto failed;
    if (st.st_uid != getuid() || (st.st_mode & 0777) != 0700) { errno = EACCES; goto failed; }
    char lockName[NAME_MAX + 1];
    int lockLength = snprintf(lockName, sizeof(lockName), "%s.lock", e->name);
    if (lockLength < 0 || (size_t)lockLength >= sizeof(lockName)) { errno = ENAMETOOLONG; goto failed; }
    e->lock = openat(e->directory, lockName, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (e->lock < 0 || fstat(e->lock, &st) < 0) goto failed;
    if (!S_ISREG(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 0777) != 0600 || st.st_nlink != 1) { errno = EACCES; goto failed; }
    if (flock(e->lock, LOCK_EX | LOCK_NB) < 0) goto failed;
    if (fstatat(e->directory, e->name, &st, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISSOCK(st.st_mode) || st.st_uid != getuid()) { errno = EACCES; goto failed; }
        if (unlinkat(e->directory, e->name, 0) < 0) goto failed;
    } else if (errno != ENOENT) goto failed;
    if (!realpath(parent, resolved)) goto failed;
    struct sockaddr_un address = { .sun_family = AF_UNIX, .sun_len = sizeof(address) };
    int addressLength = snprintf(address.sun_path, sizeof(address.sun_path), "%s/%s", resolved, e->name);
    if (addressLength < 0 || (size_t)addressLength >= sizeof(address.sun_path)) { errno = ENAMETOOLONG; goto failed; }
    e->listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (e->listener < 0 || descriptor_flags(e->listener) < 0 || bind(e->listener, (struct sockaddr *)&address, sizeof(address)) < 0) goto failed;
    if (fstatat(e->directory, e->name, &st, AT_SYMLINK_NOFOLLOW) < 0) goto failed;
    e->device = st.st_dev; e->inode = st.st_ino;
    if (fchmodat(e->directory, e->name, 0600, 0) < 0 || listen(e->listener, 64) < 0) goto failed;
    return e;
failed:
    kite_endpoint_close(e); return NULL;
}
int kite_endpoint_fd(KiteEndpoint *e) { return e->listener; }
int kite_accept(int listener) {
    int fd = accept(listener, NULL, NULL);
    if (fd < 0) return -1;
    uid_t uid; gid_t gid;
    int one = 1;
    if (getpeereid(fd, &uid, &gid) < 0 || uid != getuid() || descriptor_flags(fd) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) < 0) {
        int error = errno ? errno : EACCES; close(fd); errno = error; return -1;
    }
    return fd;
}
static void sane_termios(struct termios *t) {
    memset(t, 0, sizeof(*t));
    t->c_iflag = BRKINT | ICRNL | IXON | IMAXBEL;
    t->c_oflag = OPOST | ONLCR;
    t->c_cflag = CREAD | CS8 | HUPCL;
    t->c_lflag = ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOCTL;
    for (size_t i = 0; i < NCCS; ++i) t->c_cc[i] = _POSIX_VDISABLE;
    t->c_cc[VINTR] = 3; t->c_cc[VQUIT] = 28; t->c_cc[VERASE] = 127;
    t->c_cc[VKILL] = 21; t->c_cc[VEOF] = 4; t->c_cc[VSTART] = 17;
    t->c_cc[VSTOP] = 19; t->c_cc[VSUSP] = 26; t->c_cc[VREPRINT] = 18;
    t->c_cc[VWERASE] = 23; t->c_cc[VLNEXT] = 22; t->c_cc[VMIN] = 1;
    cfsetispeed(t, B38400); cfsetospeed(t, B38400);
}
static int inherit_variable(const char *s) {
    const char *remove[] = {"TERM=", "COLORTERM=", "TERM_PROGRAM=", "TERM_PROGRAM_VERSION=", "TMUX=", "TMUX_PANE=", "STY=", "GHOSTTY_RESOURCES_DIR=", "GHOSTTY_BIN_DIR=", "PWD=", "SHLVL="};
    for (size_t i = 0; i < sizeof(remove) / sizeof(remove[0]); ++i) if (!strncmp(s, remove[i], strlen(remove[i]))) return 0;
    return 1;
}
int kite_pty_spawn(const char *shell, const char *cwd, bool login, uint16_t rows, uint16_t cols, int32_t *pid) {
    size_t count = 0; while (environ[count]) ++count;
    char **environment = calloc(count + 6, sizeof(char *));
    if (!environment) return -1;
    size_t n = 0;
    for (size_t i = 0; i < count; ++i) if (inherit_variable(environ[i])) environment[n++] = environ[i];
    environment[n++] = "TERM=xterm-256color"; environment[n++] = "COLORTERM=truecolor";
    environment[n++] = "TERM_PROGRAM=Kite";
    char pwd[PATH_MAX + 5], arg0[PATH_MAX];
    int pwdLength = snprintf(pwd, sizeof(pwd), "PWD=%s", cwd);
    if (pwdLength < 0 || (size_t)pwdLength >= sizeof(pwd)) { free(environment); errno = ENAMETOOLONG; return -1; }
    environment[n++] = pwd;
    const char *base = strrchr(shell, '/'); base = base ? base + 1 : shell;
    int argumentLength = snprintf(arg0, sizeof(arg0), "%s%s", login ? "-" : "", base);
    if (argumentLength < 0 || (size_t)argumentLength >= sizeof(arg0)) { free(environment); errno = ENAMETOOLONG; return -1; }
    char *argv[] = { arg0, "-i", NULL };
    int errors[2];
    if (pipe(errors) < 0) { free(environment); return -1; }
    fcntl(errors[0], F_SETFD, FD_CLOEXEC); fcntl(errors[1], F_SETFD, FD_CLOEXEC);
    int limit = getdtablesize(), master = -1;
    struct termios terminal; sane_termios(&terminal);
    struct winsize size = {rows, cols, 0, 0};
    pid_t child = forkpty(&master, NULL, &terminal, &size);
    if (child == 0) {
        close(errors[0]);
        struct sigaction action; memset(&action, 0, sizeof(action)); action.sa_handler = SIG_DFL;
        sigemptyset(&action.sa_mask);
        for (int s = 1; s < NSIG; ++s) if (s != SIGKILL && s != SIGSTOP) sigaction(s, &action, NULL);
        sigset_t empty; sigemptyset(&empty); sigprocmask(SIG_SETMASK, &empty, NULL);
        for (int fd = 3; fd < limit; ++fd) if (fd != errors[1]) close(fd);
        if (chdir(cwd) == 0) execve(shell, argv, environment);
        int error = errno; (void)write(errors[1], &error, sizeof(error)); _exit(127);
    }
    int error = errno; close(errors[1]); free(environment);
    if (child < 0) { close(errors[0]); errno = error; return -1; }
    int execError = 0; ssize_t received;
    do { received = read(errors[0], &execError, sizeof(execError)); } while (received < 0 && errno == EINTR);
    close(errors[0]);
    if (received != 0 || descriptor_flags(master) < 0) {
        error = received > 0 ? execError : errno;
        kill(child, SIGKILL); while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        close(master); errno = error; return -1;
    }
    *pid = child; return master;
}
int kite_pty_resize(int fd, uint16_t rows, uint16_t cols, uint16_t width, uint16_t height) {
    struct winsize size = {rows, cols, width, height}; return ioctl(fd, TIOCSWINSZ, &size);
}
int kite_pty_cwd(int32_t pid, char *buffer, size_t capacity) {
    struct proc_vnodepathinfo info;
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info)) != sizeof(info)) return -1;
    size_t length = strnlen(info.pvi_cdir.vip_path, sizeof(info.pvi_cdir.vip_path));
    if (length >= capacity) { errno = ENAMETOOLONG; return -1; }
    memcpy(buffer, info.pvi_cdir.vip_path, length + 1); return 0;
}
int kite_child_exited(int32_t pid) {
    siginfo_t info; memset(&info, 0, sizeof(info));
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) < 0) return -1;
    return info.si_pid == pid;
}
int kite_reap(int32_t pid, int32_t *code) {
    int status; pid_t result;
    do { result = waitpid(pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
    if (result <= 0) return (int)result;
    *code = WIFEXITED(status) ? WEXITSTATUS(status) : WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 1;
    return 1;
}
struct identity { pid_t pid; uint64_t seconds, micros; };
struct KiteProcessTree { size_t count; struct identity *members; };
static int identity(pid_t pid, struct identity *out) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return -1;
    *out = (struct identity){pid, info.pbi_start_tvsec, info.pbi_start_tvusec}; return 0;
}
static void signal_member(struct identity expected, int sig) {
    struct identity actual;
    if (expected.pid > 1 && expected.pid != getpid() && identity(expected.pid, &actual) == 0 &&
        actual.seconds == expected.seconds && actual.micros == expected.micros) kill(expected.pid, sig);
}
KiteProcessTree *kite_process_tree_capture(int32_t pid) {
    if (pid <= 1) return NULL;
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0}; size_t length = 0;
    if (sysctl(mib, 4, NULL, &length, NULL, 0) < 0) return NULL;
    length += 128 * sizeof(struct kinfo_proc);
    struct kinfo_proc *processes = malloc(length);
    KiteProcessTree *tree = calloc(1, sizeof(*tree));
    if (!processes || !tree) { free(processes); free(tree); return NULL; }
    if (sysctl(mib, 4, processes, &length, NULL, 0) < 0) { free(processes); free(tree); return NULL; }
    size_t count = length / sizeof(*processes);
    tree->members = calloc(count + 1, sizeof(*tree->members));
    bool *owned = calloc(count, sizeof(bool));
    if (!tree->members || !owned) { free(owned); free(tree->members); free(tree); free(processes); return NULL; }
    // Job-control groups share the shell's session, even after reparenting.
    // Also follow descendants that deliberately established another session.
    for (size_t i = 0; i < count; ++i) {
        pid_t current = processes[i].kp_proc.p_pid;
        owned[i] = current == pid || (current > 1 && getsid(current) == pid);
    }
    for (size_t pass = 0; pass < count; ++pass) {
        bool changed = false;
        for (size_t i = 0; i < count; ++i) if (!owned[i]) {
            for (size_t j = 0; j < count; ++j) if (owned[j] && processes[i].kp_eproc.e_ppid == processes[j].kp_proc.p_pid) {
                owned[i] = true; changed = true; break;
            }
        }
        if (!changed) break;
    }
    for (size_t i = 0; i < count; ++i) if (owned[i] && identity(processes[i].kp_proc.p_pid, &tree->members[tree->count]) == 0) ++tree->count;
    free(owned); free(processes);
    return tree;
}
void kite_process_tree_dispose(KiteProcessTree *tree) {
    if (!tree) return;
    free(tree->members); free(tree);
}
void kite_process_tree_signal(KiteProcessTree *tree) {
    if (!tree) return;
    for (size_t i = tree->count; i > 0; --i) {
        signal_member(tree->members[i - 1], SIGHUP);
        signal_member(tree->members[i - 1], SIGCONT);
        signal_member(tree->members[i - 1], SIGTERM);
    }
}
KiteProcessTree *kite_terminate_begin(int32_t pid) {
    KiteProcessTree *tree = kite_process_tree_capture(pid);
    kite_process_tree_signal(tree);
    return tree;
}
void kite_terminate_finish(KiteProcessTree *tree) {
    if (!tree) return;
    for (size_t i = 0; i < tree->count; ++i) signal_member(tree->members[i], SIGKILL);
    kite_process_tree_dispose(tree);
}
