#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

int main(int argc, char **argv) {
  if (argc != 3 || argv[2][0] != '/') return 125;
  if (setsid() < 0) return 125;
#ifdef __linux__
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return 125;
#endif
  if (strcmp(argv[1], "bash") == 0) {
    execl("/bin/bash", "bash", "--noprofile", "--norc", "-eo", "pipefail", argv[2], (char *)0);
  } else if (strcmp(argv[1], "sh") == 0) {
    execl("/bin/sh", "sh", "-e", argv[2], (char *)0);
  } else if (strcmp(argv[1], "") == 0) {
    execl("/bin/bash", "bash", "--noprofile", "--norc", "-e", argv[2], (char *)0);
  } else {
    return 125;
  }
  int error = errno;
  fputs("runner: failed to start shell\n", stderr);
  return error == ENOENT ? 127 : 126;
}
