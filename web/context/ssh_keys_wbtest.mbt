///|
test "SSH settings CSRF tokens are session-bound and not login credentials" {
  let first = form_csrf_token("first-session", "ssh-key-settings")
  let second = form_csrf_token("second-session", "ssh-key-settings")
  assert_eq(first.length(), 64)
  assert_true(first != second)
  assert_true(first != @identity.hash_token("first-session"))
  assert_true(valid_form_token(first, first))
  assert_true(!valid_form_token(first, second))
  assert_true(!valid_form_token(first, ""))
  assert_true(!valid_form_token(first, first + "0"))
  assert_true(!valid_form_token("", ""))
}
