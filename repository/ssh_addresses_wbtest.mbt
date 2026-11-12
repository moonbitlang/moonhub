///|
test "SSH endpoints normalize hosts and encode repository URL segments" {
  let endpoint = SshEndpoint::from_url(" ssh://git@Git.Example.COM:12222/ ")
  assert_eq(endpoint.host, "git.example.com")
  assert_eq(endpoint.port, 12222)
  assert_eq(
    endpoint.clone_url({ owner: "a b", name: "repo?#", }),
    "ssh://git@git.example.com:12222/a%20b/repo%3F%23.git",
  )
  assert_eq(SshEndpoint::from_url("ssh://git@localhost").port, 22)
  assert_eq(
    SshEndpoint::from_fields("127.0.0.1", "22").authority(),
    "127.0.0.1:22",
  )
  assert_eq(
    SshEndpoint::from_url("ssh://git@[2001:0db8::1]:2222").authority(),
    "[2001:db8::1]:2222",
  )
  assert_eq(SshEndpoint::from_fields("::1", "22").authority(), "[::1]:22")
  let source = parse_ssh_import_source(
    "ssh://git@[2001:db8::1]:2222/team/repo.git",
  )
  assert_eq(source.host, "2001:db8::1")
  assert_eq(source.user, "git")
  assert_eq(source.path, "team/repo.git")
}

///|
test "SSH endpoints reject listen addresses credentials paths and invalid ports" {
  for
    value in [
      "ssh://git@0.0.0.0:22", "ssh://git@[::]:22", "ssh://git@[fe80::1%en0]:22",
      "ssh://git@999.1.1.1", "ssh://bob@host", "https://git@host", "ssh://git:secret@host",
      "ssh://git@host/repo.git", "ssh://git@host:0", "ssh://git@host:65536", "ssh://git@host:-1",
      "ssh://git@host:22?x=1", "ssh://git@host:22#x", "ssh://git@bad host", "ssh://git@host:22/path/",
      "ssh://git@::1",
    ] {
    try SshEndpoint::from_url(value) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted invalid endpoint: \{value}")
    }
  }
}
