// SPDX-License-Identifier: GPL-3.0-or-later
// AL NOTE-owned exact-write transport. Never parses PDF or response metadata.
// Dart IOSink completion is not proof of kernel pipe transmission. Success here
// requires two complete bounded request frames written and a reaped zero-exit
// launcher. The Dart supervisor independently validates output and cgroup cleanup.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;
static void stop(int signal_number) { (void)signal_number; stopping = 1; }
static void wake(int signal_number) { (void)signal_number; }

struct framing {
  uint32_t length;
  uint32_t remaining;
  unsigned header_used;
  unsigned frames;
};

static int check_input(struct framing *state, const unsigned char *bytes, size_t count) {
  for (size_t i = 0; i < count; ++i) {
    if (state->frames == 2) return -1;
    if (state->header_used < 4) {
      state->length = (state->length << 8) | bytes[i];
      if (++state->header_used == 4) {
        if (!state->length || state->length > (state->frames ? 50000000U : 1024U)) return -1;
        state->remaining = state->length;
      }
    } else if (--state->remaining == 0) {
      ++state->frames;
      state->header_used = 0;
      state->length = 0;
    }
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2 || argv[1][0] != '/') return 80;
  struct sigaction action = {0};
  action.sa_handler = stop;
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, NULL);
  sigaction(SIGINT, &action, NULL);
  action.sa_handler = wake;
  sigaction(SIGCHLD, &action, NULL);
  signal(SIGPIPE, SIG_IGN);
  pid_t parent = getppid();
  if (prctl(PR_SET_PDEATHSIG, SIGTERM) || getppid() != parent) return 81;
  int input[2];
  if (pipe2(input, O_CLOEXEC)) return 82;
  pid_t transport = getpid();
  pid_t child = fork();
  if (child < 0) return 83;
  if (child == 0) {
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != transport) _exit(84);
    close(input[1]);
    if (dup2(input[0], STDIN_FILENO) < 0) _exit(84);
    close(input[0]);
    execv(argv[1], argv + 1);
    _exit(85);
  }
  close(input[0]);
  int fd = input[1];
  if (fcntl(fd, F_SETFL, O_NONBLOCK)) stopping = 1;
  unsigned char buffer[65536];
  size_t used = 0, sent = 0;
  uint64_t total_read = 0, total_written = 0;
  struct framing framing = {0};
  int status = 0, reaped = 0, complete = 0, rejected = 0;
  sigset_t blocked, previous;
  sigemptyset(&blocked);
  sigaddset(&blocked, SIGCHLD);
  sigaddset(&blocked, SIGTERM);
  sigaddset(&blocked, SIGINT);
  if (sigprocmask(SIG_BLOCK, &blocked, &previous)) stopping = 1;
  while (!stopping) {
    pid_t result = waitpid(child, &status, WNOHANG);
    if (result == child) { reaped = 1; break; }
    if (result < 0 && errno != EINTR) { rejected = 1; break; }
    if (used == sent && framing.frames == 2) {
      complete = total_written == total_read && total_written > 8;
      if (fd >= 0) close(fd);
      fd = -1;
    }
    struct pollfd watch = {.fd = complete ? -1 : (used == sent ? STDIN_FILENO : fd),
                           .events = used == sent ? POLLIN : POLLOUT};
    // Atomically restore the signal mask while waiting: child exit/cancellation
    // between waitpid/check and registration cannot be lost.
    int ready = ppoll(&watch, 1, NULL, &previous);
    if (ready < 0) {
      if (errno == EINTR) continue;
      rejected = 1; break;
    }
    if (used == sent) {
      ssize_t count = read(STDIN_FILENO, buffer, sizeof buffer);
      if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
      if (count <= 0 || check_input(&framing, buffer, (size_t)count)) { rejected = 1; break; }
      used = (size_t)count;
      sent = 0;
      total_read += used;
    } else {
      ssize_t count = write(fd, buffer + sent, used - sent);
      if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
      if (count <= 0) { rejected = 1; break; }
      sent += (size_t)count;
      total_written += (size_t)count;
    }
  }
  sigprocmask(SIG_SETMASK, &previous, NULL);
  // Child exit can race the next iteration after the last successful write.
  complete = complete || (framing.frames == 2 && used == sent && total_read == total_written);
  if (fd >= 0) close(fd);
  if (!reaped) {
    kill(child, SIGKILL);
    pid_t result;
    do { result = waitpid(child, &status, 0); } while (result < 0 && errno == EINTR);
    reaped = result == child;
  }
  return !stopping && !rejected && complete && reaped && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 86;
}
