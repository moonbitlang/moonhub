#include <stdint.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <sddl.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#ifdef _MSC_VER
#pragma comment(lib, "advapi32.lib")
#endif
int32_t moonhub_platform_protect_directory(const uint16_t *path, int32_t length, int32_t readable) {
  HANDLE token = NULL;
  DWORD size = 0;
  TOKEN_USER *user = NULL;
  LPWSTR sid = NULL;
  PSECURITY_DESCRIPTOR descriptor = NULL;
  wchar_t *name = NULL, *sddl = NULL;
  int32_t result = -1;
  if (length < 1 || !OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) goto done;
  GetTokenInformation(token, TokenUser, NULL, 0, &size);
  user = (TOKEN_USER *)malloc(size);
  if (!user || !GetTokenInformation(token, TokenUser, user, size, &size) ||
      !ConvertSidToStringSidW(user->User.Sid, &sid)) goto done;
  name = (wchar_t *)calloc((size_t)length + 1, sizeof(wchar_t));
  sddl = (wchar_t *)calloc(wcslen(sid) + 200, sizeof(wchar_t));
  if (!name || !sddl) goto done;
  memcpy(name, path, (size_t)length * sizeof(wchar_t));
  swprintf(sddl, wcslen(sid) + 200, L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;%ls)%ls", sid,
      readable ? L"(A;OICI;FRFX;;;AU)" : L"");
  if (ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, &descriptor, NULL) &&
      SetFileSecurityW(name, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, descriptor)) result = 0;
done:
  if (descriptor) LocalFree(descriptor);
  if (sid) LocalFree(sid);
  if (token) CloseHandle(token);
  free(user); free(name); free(sddl);
  return result;
}
#else
int32_t moonhub_platform_protect_directory(const uint16_t *path, int32_t length, int32_t readable) {
  (void)path; (void)length; (void)readable; return 0;
}
#endif
