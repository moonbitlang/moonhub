///|
test "workspace containment respects path component boundaries" {
  assert_true(@platform.within("/workspace", "/workspace/repo"))
  assert_true(!@platform.within("/workspace", "/workspace-other/repo"))
  for
    path in [
      "../escape", "a/../escape", "/absolute", "C:stream", "a\\b", "a//b",
    ] {
    assert_true(!@platform.valid_relative(path))
  }
  assert_true(@platform.valid_relative("."))
  assert_true(@platform.valid_relative("source/test files"))
}

///|
#cfg(platform="windows")
test "Windows paths reject device files and normalize realpath spellings" {
  assert_true(@platform.windows())
  assert_true(@platform.within("C:/Workspace", "\\\\?\\C:\\workspace\\repo"))
  assert_true(!@platform.within("C:/Workspace", "C:/workspace-other"))
  for
    path in [
      "NUL", "con.txt", "folder/LPT1", "trailing.", "trailing ", "file:stream",
    ] {
    assert_true(!@platform.valid_relative(path))
  }
}

///|
test "native environment metadata has a supported architecture and platform-specific Windows build" {
  assert_true(["x64", "arm64"].contains(@platform.architecture()))
  if @platform.windows() {
    assert_true(@platform.windows_build() > 0)
  } else {
    assert_eq(@platform.windows_build(), 0)
  }
}
