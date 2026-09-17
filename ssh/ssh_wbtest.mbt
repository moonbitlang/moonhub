///|
test "SSH keys normalize comments and whitespace and reject injected options" {
  let plain = parse_ssh_public_key(@test_support.test_ssh_public_key)
  let decorated = parse_ssh_public_key(
    "  \{@test_support.test_ssh_public_key}\tlaptop\n",
  )
  assert_eq(plain.public_key, decorated.public_key)
  assert_eq(plain.fingerprint, decorated.fingerprint)
  assert_true(plain.fingerprint.has_prefix("SHA256:"))
  assert_true(!plain.fingerprint.has_suffix("="))
  for
    invalid in [
      "command=\"id\" \{@test_support.test_ssh_public_key}",
      "\{@test_support.test_ssh_public_key}\n\{@test_support.test_ssh_public_key}",
      "ssh-ed25519 !!!",
      "ssh-ed25519 YWJj",
      "ssh-rsa YWJj",
      "",
    ] {
    try parse_ssh_public_key(invalid) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted invalid SSH key: \{invalid}")
    }
  }
}

///|
test "SSH commands accept both Git URL forms without interpreting a shell" {
  let fetch = parse_ssh_request("git-upload-pack 'alice/demo.git'")
  assert_eq(fetch.repo.path(), "alice/demo")
  assert_true(fetch.operation is @repository.Read)
  let push = parse_ssh_request("git-receive-pack '/alice/demo.git'")
  assert_eq(push.repo.path(), "alice/demo")
  assert_true(push.operation is @repository.Write)
  for
    command in [
      "id", "bash -c 'id'", "git-upload-archive 'alice/demo.git'", "git-upload-pack 'alice/demo.git'; id",
      "git-upload-pack 'alice/demo.git' 'bob/demo.git'", "git-upload-pack '--help'",
      "git-upload-pack '../demo.git'", "git-upload-pack 'alice/../demo.git'", "git-upload-pack '//alice/demo.git'",
      "git-upload-pack '~alice/demo.git'", "git-upload-pack 'alice/demo.git\n'",
      "git-upload-pack 'alice/demo$(id).git'", "git-upload-pack 'alice/demo\\.git'",
      "git-upload-pack 'assets/demo.git'", "git-upload-pack 'alice/%2e%2e.git'",
      "git-upload-pack alice/demo.git",
    ] {
    try parse_ssh_request(command) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted unsafe SSH command: \{command}")
    }
  }
  // Leading slashes in ssh:// URLs name application repositories, never host paths.
  assert_eq(
    parse_ssh_request("git-upload-pack '/etc/passwd'").repo.path(),
    "etc/passwd",
  )
}

///|
async test "revoked or disabled SSH identities cannot authenticate or open another channel" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let key = parse_ssh_public_key(@test_support.test_ssh_public_key)
    let id = add_ssh_key(pool, alice, "Laptop", key)
    assert_eq(ssh_key_user(pool, id).id, alice.id)
    assert_true(
      authorized_ssh_key(pool, key)
      .unwrap()
      .has_prefix("restrict,command=\"/usr/local/bin/moonhub ssh-serve "),
    )
    try
      add_ssh_key(
        pool,
        @identity.active_user_by_name(pool, "bob"),
        "Duplicate",
        key,
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted a duplicate identity key")
    }
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET status = 'disabled' WHERE id = 1",
      )
    })
    assert_true(authorized_ssh_key(pool, key) is None)
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET status = 'active' WHERE id = 1",
      )
      let _ = client.execute(
        "UPDATE ssh_key SET revoked_at = datetime('now') WHERE id = ?",
        params=[id],
      )
    })
    assert_true(authorized_ssh_key(pool, key) is None)
    try ssh_key_user(pool, id) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("revoked key opened another session")
    }
  })
}
