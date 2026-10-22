/*
 * Small POSIX shims for exit status and daemon lifecycle. Keep networking,
 * configuration, and the MCP protocol in MoonBit.
 */

#include <moonbit.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

MOONBIT_FFI_EXPORT
void mcpbox_exit(int32_t code) {
  exit((int)code);
}

/* Paths are borrowed, NUL-terminated UTF-8 Bytes from MoonBit. Reject a
 * symlink, a foreign owner, or permissions that disclose the IPC secret. */
MOONBIT_FFI_EXPORT
int32_t mcpbox_private_directory(const unsigned char *path) {
  struct stat st;
  return lstat((const char *)path, &st) == 0 && S_ISDIR(st.st_mode) &&
         st.st_uid == geteuid() && (st.st_mode & 0077) == 0;
}

/* fcntl locks are released by the OS on exit, including crashes. Keep the
 * lock file in place forever: unlinking it would allow two locked inodes.
 * Return -1 for an already-running daemon, -2 for an actual filesystem error.
 * CLOEXEC prevents MCP children from retaining the service's lock descriptor. */
MOONBIT_FFI_EXPORT
int32_t mcpbox_daemon_lock(const unsigned char *path) {
  int fd = open((const char *)path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
  struct stat st;
  if (fd < 0) return -2;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != geteuid() ||
      (st.st_mode & 0077) != 0) {
    close(fd);
    return -2;
  }
  struct flock lock = {0};
  lock.l_type = F_WRLCK;
  lock.l_whence = SEEK_SET;
  if (fcntl(fd, F_SETLK, &lock) == -1) {
    int busy = errno == EACCES || errno == EAGAIN;
    close(fd);
    return busy ? -1 : -2;
  }
  /* Detach from the invoking terminal; stdio is redirected by the launcher. */
  (void)setsid();
  return fd;
}

MOONBIT_FFI_EXPORT
int32_t mcpbox_is_tty(int32_t fd) {
  return isatty((int)fd) == 1;
}

MOONBIT_FFI_EXPORT
void mcpbox_close_fd(int32_t fd) {
  if (fd >= 0) close((int)fd);
}

MOONBIT_FFI_EXPORT
void mcpbox_signal_child(int32_t pid, int32_t signal_number) {
  if (pid > 0) (void)kill((pid_t)pid, (int)signal_number);
}
