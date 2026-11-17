#ifndef MOONHUB_CI_PROFILE_H
#define MOONHUB_CI_PROFILE_H
#ifdef __linux__
#include <sys/stat.h>
#include <stdio.h>
#include <string.h>
static int moonhub_ci_profile(void) {
  struct stat file;
  const char *path = "/run/moonhub-ci/profile";
  if (lstat(path, &file) != 0 || !S_ISREG(file.st_mode) ||
      file.st_uid != 0 || (file.st_mode & 022) || file.st_size != 12) return 0;
  FILE *input = fopen(path, "r");
  if (!input) return 0;
  char value[13] = {0};
  size_t size = fread(value, 1, 12, input);
  fclose(input);
  return size == 12 && memcmp(value, "linux-ci-v1\n", 12) == 0;
}
#endif
#endif
