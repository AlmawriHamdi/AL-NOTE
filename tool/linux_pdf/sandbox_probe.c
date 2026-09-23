// SPDX-License-Identifier: GPL-3.0-or-later
// Local diagnostic only: this program contains no PDF parser or engine loader.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdint.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

int alnote_restrict(void);

static int thread_pipe[2];
static int thread_network_denied;
static void *existing_thread(void *unused) {
  (void)unused;
  char start;
  if (read(thread_pipe[0], &start, 1) != 1) return NULL;
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  thread_network_denied = fd < 0 && errno == EPERM;
  if (fd >= 0) close(fd);
  return NULL;
}

static void emit(const char *text) {
  uint32_t length = htonl(strlen(text));
  if (fwrite(&length, 4, 1, stdout) != 1 ||
      fwrite(text, strlen(text), 1, stdout) != 1 || fflush(stdout)) _exit(91);
}

static int absent(const char *path) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return errno == ENOENT || errno == EACCES;
  close(fd);
  return 0;
}

int main(void) {
  pthread_t thread;
  if (pipe(thread_pipe) || pthread_create(&thread, NULL, existing_thread, NULL)) return 89;
  if (alnote_restrict()) return 90;
  if (write(thread_pipe[1], "x", 1) != 1 || pthread_join(thread, NULL)) return 89;
  close(thread_pipe[0]);
  close(thread_pipe[1]);
  emit("{\"ready\":true}");
  uint32_t wire;
  char command[65] = {0};
  if (fread(&wire, 4, 1, stdin) != 1) return 92;
  uint32_t size = ntohl(wire);
  if (!size || size > 64 || fread(command, size, 1, stdin) != 1) return 93;
  if (!strcmp(command, "probe")) {
    int net = socket(AF_INET, SOCK_STREAM, 0);
    int net_denied = net < 0 && errno == EPERM;
    int ipc = socket(AF_UNIX, SOCK_STREAM, 0);
    int ipc_denied = ipc < 0 && errno == EPERM;
    int write_fd = open("/runtime/probe", O_WRONLY | O_TRUNC);
    int read_only = write_fd < 0 && errno == EROFS;
    struct rlimit core;
    if (getrlimit(RLIMIT_CORE, &core)) return 94;
    char result[600];
    snprintf(result, sizeof(result),
      "{\"home_absent\":%d,\"network_denied\":%d,\"ipc_denied\":%d,"
      "\"display_absent\":%d,\"session_absent\":%d,\"runtime_read_only\":%d,"
      "\"environment_cleared\":%d,\"core_disabled\":%d,\"thread_network_denied\":%d,\"pid\":%d}",
      absent("/home") && absent("/var/home"), net_denied, ipc_denied,
      absent("/tmp/.X11-unix") && !getenv("DISPLAY") && !getenv("WAYLAND_DISPLAY"),
      absent("/run/user") && !getenv("DBUS_SESSION_BUS_ADDRESS"), read_only,
      !getenv("HOME") && !getenv("LD_PRELOAD") && !getenv("PDFIUM_PATH"),
      core.rlim_cur == 0, thread_network_denied, getpid());
    emit(result);
  } else if (!strcmp(command, "tasks")) {
    pid_t children[128];
    int count = 0, denied = 0;
    for (; count < 128; ++count) {
      pid_t child = fork();
      if (!child) { for (;;) pause(); }
      if (child < 0) { denied = errno == EAGAIN; break; }
      children[count] = child;
    }
    for (int i = 0; i < count; ++i) kill(children[i], SIGKILL);
    for (int i = 0; i < count; ++i) waitpid(children[i], NULL, 0);
    char result[100];
    snprintf(result, sizeof(result), "{\"children\":%d,\"denied\":%d}", count, denied);
    emit(result);
  } else if (!strcmp(command, "memory")) {
    for (;;) {
      volatile char *block = mmap(NULL, 16 * 1024 * 1024, PROT_READ | PROT_WRITE,
                                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
      if (block == MAP_FAILED) return 95;
      for (size_t i = 0; i < 16 * 1024 * 1024; i += 4096) block[i] = 1;
    }
  } else if (!strcmp(command, "sleep")) {
    for (;;) pause();
  } else if (!strcmp(command, "crash")) {
    abort();
  } else if (!strcmp(command, "flood")) {
    for (;;) emit("{\"padding\":\"012345678901234567890123456789\"}");
  } else if (!strcmp(command, "badlength")) {
    wire = htonl(UINT32_MAX);
    if (fwrite(&wire, 4, 1, stdout) != 1 || fflush(stdout)) return 96;
  } else {
    return 97;
  }
  return 0;
}
