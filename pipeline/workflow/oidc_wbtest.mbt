///|
test "OIDC permission inheritance replacement and legacy decoding are explicit" {
  assert_false(parse(basic_workflow).jobs[0].id_token_write)
  let granted = "permissions: {contents: read, id-token: write}\n" +
    basic_workflow
  assert_true(parse(granted).jobs[0].id_token_write)
  assert_true(parse(granted).jobs[0].contents_read)
  let replaced = parse(granted + "\n    permissions: {contents: read}").jobs[0]
  assert_false(replaced.id_token_write)
  assert_true(replaced.contents_read)
  let only_oidc = parse(basic_workflow + "\n    permissions: {id-token: write}").jobs[0]
  assert_true(only_oidc.id_token_write)
  assert_false(only_oidc.contents_read)
  assert_false(
    parse(granted + "\n    permissions: {id-token: none}").jobs[0].id_token_write,
  )
  for value in ["read", "true", "'${{ true }}'"] {
    expect_invalid(
      "permissions: {id-token: " + value + "}\n" + basic_workflow,
      "id-token",
    )
  }
  let legacy = ToJson::to_json(parse(basic_workflow))
    .stringify()
    .replace_all(old="\"id_token_write\":false,", new="")
  let decoded : Workflow = @json.from_json(@json.parse(legacy))
  assert_false(decoded.jobs[0].id_token_write)
  for name in ["ACTIONS_ID_TOKEN_REQUEST_TOKEN", "actions_id_token_request_url"] {
    expect_invalid(
      basic_workflow + "\n    env: {" + name + ": spoof}",
      "reserved",
    )
  }
}
