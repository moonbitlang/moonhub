#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>
#include <errno.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

int64_t moonhub_runner_monotonic(void) {
  struct timespec t;
#ifdef CLOCK_BOOTTIME
  if (clock_gettime(CLOCK_BOOTTIME, &t) != 0) return -1;
#else
  if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) return -1;
#endif
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

int32_t moonhub_runner_prepare(int32_t local) {
  if (local) return 0;
#ifdef __linux__
  if (getpid() != 1 || geteuid() == 0) return -1;
  if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0) return -1;
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return -1;
  return 0;
#else
  return -1;
#endif
}

void moonhub_runner_kill_group(int32_t pid) {
  if (pid <= 1) return;
  kill(-pid, SIGKILL);
  kill(pid, SIGKILL);
}

void moonhub_runner_kill_namespace(void) {
#ifdef __linux__
  if (getpid() == 1 && geteuid() != 0) kill(-1, SIGKILL);
#endif
}

int32_t moonhub_runner_reap_namespace(void) {
  int status;
  pid_t pid;
  do { pid = waitpid(-1, &status, WNOHANG); } while (pid > 0);
  return pid < 0 && errno == ECHILD ? 0 : 1;
}
