///|
test "repository identities preserve the Git suffix in the actual name" {
  assert_eq(parse_repo_name("alice/docs.git").path(), "alice/docs.git")
  assert_eq(
    parse_transport_repo("/alice/docs.git.git").path(),
    "alice/docs.git",
  )
  assert_eq(parse_transport_repo("/alice/docs.git").path(), "alice/docs")
}

///|
test "assets and the route separator are reserved repository owners" {
  assert_true(valid_repo_owner("alice"))
  assert_true(!valid_repo_owner(PUBLIC_ASSETS_OWNER))
  assert_true(!valid_repo_owner(RESERVED_PATH_SEGMENT))
  assert_true(valid_repo_name("alice"))
  assert_true(!valid_repo_name(RESERVED_PATH_SEGMENT))
}
