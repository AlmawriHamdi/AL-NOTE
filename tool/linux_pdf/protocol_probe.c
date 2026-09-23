// SPDX-License-Identifier: GPL-3.0-or-later
// Hostile protocol diagnostic, adapted from the independent audit reproducer.
// No parser: emit controlled /runtime/response bytes under the actual guard.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int alnote_restrict(void);

static void frame(const char *text) {
  uint32_t length = htonl(strlen(text));
  fwrite(&length, 4, 1, stdout);
  fwrite(text, strlen(text), 1, stdout);
  fflush(stdout);
}

int main(void) {
  if (alnote_restrict()) return 90;
  FILE *mode = fopen("/runtime/mode", "r");
  int action = 0;
  if (!mode || fscanf(mode, "%d", &action) != 1) return 89;
  fclose(mode);
  if (action == 8) return 0;
  frame("{\"ready\":true}");
  if (action == 3) usleep(150000); // Plausible success without reading input.
  if (action == 9) { // Broken pipe with no final response, worker still alive.
    fclose(stdin);
    for (;;) pause();
  }
  if (action != 3 && action != 10) {
    for (int i = 0; i < 2; i++) {
      uint32_t length;
      if (fread(&length, 4, 1, stdin) != 1) return 91;
      length = ntohl(length);
      while (length--) {
        if (getchar() == EOF) return 92;
      }
    }
  }
  if (action == 5) {
    for (int i = 0; i < 5000; i++) fputc('x', stderr);
    fflush(stderr);
  }
  if (action == 6 && fork() == 0) {
    setsid();
    signal(SIGTERM, SIG_IGN);
    for (;;) pause();
  }
  FILE *response = fopen("/runtime/response", "rb");
  if (!response) return 93;
  char buffer[4096];
  size_t count;
  while ((count = fread(buffer, 1, sizeof buffer, response))) {
    fwrite(buffer, 1, count, stdout);
  }
  fflush(stdout);
  fclose(response);
  if (action == 11) raise(SIGSEGV); // Valid-looking output followed by a crash.
  if (action == 2 || action == 6) {
    for (;;) pause();
  }
  if (action == 4) {
    fclose(stdout);
    fclose(stderr);
    for (;;) pause();
  }
  return action == 1 ? 23 : 0;
}
