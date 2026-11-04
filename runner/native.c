#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <sddl.h>
#ifdef _MSC_VER
#pragma comment(lib, "advapi32.lib")
#endif
int64_t moonhub_runner_monotonic(void) { return (int64_t)GetTickCount64(); }
int32_t moonhub_runner_prepare(int32_t local) {
  if (local) return 0;
  DWORD type = 0, size = sizeof(type);
  if (RegGetValueW(HKEY_LOCAL_MACHINE, L"SYSTEM\\CurrentControlSet\\Control", L"ContainerType", RRF_RT_REG_DWORD, NULL, &type, &size) != ERROR_SUCCESS) return -1;
  BYTE sid[SECURITY_MAX_SID_SIZE]; DWORD sid_size = sizeof(sid); BOOL admin = TRUE;
  if (!CreateWellKnownSid(WinBuiltinAdministratorsSid, NULL, sid, &sid_size) ||
      !CheckTokenMembership(NULL, sid, &admin) || admin) return -1;
  // Steps share ContainerUser with the agent. Remove same-user process access
  // before loading credentials, preventing ReadProcessMemory/DuplicateHandle on
  // the agent; SYSTEM and administrators retain diagnostic access.
  PSECURITY_DESCRIPTOR descriptor = NULL;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
        L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;RC;;;OW)", SDDL_REVISION_1, &descriptor, NULL)) return -1;
  BOOL protected_process = SetKernelObjectSecurity(GetCurrentProcess(),
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, descriptor);
  LocalFree(descriptor);
  return protected_process ? 0 : -1;
}
void moonhub_runner_kill_group(int32_t pid) {
  if (pid <= 0) return;
  HANDLE process = OpenProcess(PROCESS_TERMINATE, FALSE, (DWORD)pid);
  if (process) { TerminateProcess(process, 1); CloseHandle(process); }
}
// Each launcher owns a kill-on-close Job Object containing the whole step tree.
void moonhub_runner_kill_namespace(void) {}
int32_t moonhub_runner_reap_namespace(void) { return 0; }
#else
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

#endif
