#ifdef _WIN32
#define _WIN32_WINNT 0x0A00
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

// Quote a single CreateProcess argument (including trailing backslashes).
static wchar_t *quote(wchar_t *out, const wchar_t *arg) {
  *out++ = L'"';
  while (*arg) {
    size_t slashes = 0;
    while (*arg == L'\\') { ++slashes; ++arg; }
    for (size_t i = 0; i < slashes * ((*arg == L'"' || !*arg) ? 2 : 1); ++i) *out++ = L'\\';
    if (*arg == L'"') *out++ = L'\\';
    if (*arg) *out++ = *arg++;
  }
  *out++ = L'"'; *out = 0; return out;
}
int wmain(int argc, wchar_t **argv) {
  if (argc != 3 || wcslen(argv[2]) < 3 || argv[2][1] != L':') return 125;
  const wchar_t *program;
  const wchar_t *args;
  if (!*argv[1] || wcscmp(argv[1], L"pwsh") == 0) {
    program = L"pwsh.exe"; args = L" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ";
  } else if (wcscmp(argv[1], L"bash") == 0) {
    program = L"bash.exe"; args = L" --noprofile --norc -eo pipefail ";
  } else if (wcscmp(argv[1], L"sh") == 0) {
    program = L"sh.exe"; args = L" -e ";
  } else return 125;
  wchar_t executable[32768];
  DWORD found = SearchPathW(NULL, program, NULL, 32768, executable, NULL);
  if (!found || found >= 32768) return 127;
  size_t capacity = 2 * (wcslen(executable) + wcslen(argv[2])) + wcslen(args) + 16;
  if (capacity > 32768) return 125;
  wchar_t *command = (wchar_t *)calloc(capacity, sizeof(wchar_t));
  if (!command) return 125;
  wchar_t *cursor = quote(command, executable);
  if (wcscpy_s(cursor, capacity - (size_t)(cursor - command), args) != 0) { free(command); return 125; }
  cursor += wcslen(args); quote(cursor, argv[2]);
  HANDLE job = CreateJobObjectW(NULL, NULL);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
    if (job) CloseHandle(job); free(command); return 125;
  }
  // Assign atomically during creation: cancellation cannot strand an unowned
  // suspended child between CreateProcess and AssignProcessToJobObject.
  SIZE_T attribute_size = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_size);
  LPPROC_THREAD_ATTRIBUTE_LIST attributes = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attribute_size);
  if (!attributes || !InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_size)) {
    free(attributes); CloseHandle(job); free(command); return 125;
  }
  if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
        &job, sizeof(job), NULL, NULL)) {
    DeleteProcThreadAttributeList(attributes); free(attributes); CloseHandle(job); free(command); return 125;
  }
  STARTUPINFOEXW startup = {0}; PROCESS_INFORMATION child = {0};
  startup.StartupInfo.cb = sizeof(startup); startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  startup.StartupInfo.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
  startup.StartupInfo.hStdError = GetStdHandle(STD_ERROR_HANDLE);
  startup.lpAttributeList = attributes;
  BOOL started = CreateProcessW(executable, command, NULL, NULL, TRUE,
      EXTENDED_STARTUPINFO_PRESENT | CREATE_NEW_PROCESS_GROUP, NULL, NULL, &startup.StartupInfo, &child);
  DeleteProcThreadAttributeList(attributes); free(attributes); free(command);
  if (!started) { CloseHandle(job); return 126; }
  WaitForSingleObject(child.hProcess, INFINITE);
  DWORD code = 125; GetExitCodeProcess(child.hProcess, &code);
  // Also stop background descendants after an otherwise successful step.
  TerminateJobObject(job, code); CloseHandle(job);
  CloseHandle(child.hThread); CloseHandle(child.hProcess);
  return (int)code;
}
#else
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

#endif
