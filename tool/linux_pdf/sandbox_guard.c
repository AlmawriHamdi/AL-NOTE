// SPDX-License-Identifier: GPL-3.0-or-later
#define _GNU_SOURCE
#include <errno.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

// A diagnostic profile, not a reviewed Dart/PDFium runtime allowlist.
// Block ambient IPC/network, namespace changes and process-inspection APIs.
#define DENY(n) BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (n), 0, 1), \
  BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM)
int alnote_restrict(void) {
  struct sock_filter filter[] = {
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
    BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
    DENY(SYS_socket), DENY(SYS_socketpair), DENY(SYS_connect),
    DENY(SYS_ptrace), DENY(SYS_process_vm_readv), DENY(SYS_process_vm_writev),
    DENY(SYS_mount), DENY(SYS_umount2), DENY(SYS_unshare), DENY(SYS_setns),
    DENY(SYS_bpf), DENY(SYS_keyctl), DENY(SYS_userfaultfd),
    DENY(SYS_execve), DENY(SYS_execveat),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
  };
  struct sock_fprog program = {.len = sizeof(filter) / sizeof(filter[0]),
                              .filter = filter};
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) return -1;
  // TSYNC also covers runtime threads already created before this call.
  return syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER,
                 SECCOMP_FILTER_FLAG_TSYNC, &program);
}

