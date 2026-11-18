///|
fn definition(name : String, selector : String) -> Definition {
  {
    name,
    selector,
    architecture: "x64",
    image: "registry.example/runner@sha256:" + "a".repeat(64),
    labels: [],
  }
}

///|
test "environment images require an immutable bounded digest reference" {
  assert_eq(
    image_digest(definition("debian", "debian-12").image),
    Some("a".repeat(64)),
  )
  for
    image in [
      "runner:latest",
      "@sha256:" + "a".repeat(64),
      "runner@sha256:" + "A".repeat(64),
      "runner@sha256:" + "a".repeat(63),
      "-runner@sha256:" + "a".repeat(64),
      "https://example/runner@sha256:" + "a".repeat(64),
      "runner@sha256:" + "a".repeat(64) + "\n",
    ] {
    assert_eq(image_digest(image), None)
  }
}

///|
test "one provider supports separate environments with one default and architecture" {
  let debian = definition("debian", "debian-12")
  let ubuntu = definition("ubuntu", "ubuntu-24.04")
  assert_eq(validate_set([debian, ubuntu], "debian"), None)
  assert_true(validate_set([debian, ubuntu], "missing") is Some(_))
  assert_true(validate_set([debian, debian], "debian") is Some(_))
  assert_true(
    validate_set([debian, { ..ubuntu, architecture: "arm64", }], "debian")
    is Some(_),
  )
  assert_eq(validate_set([], ""), None)
  assert_true(
    validate_definition({ ..debian, labels: ["ubuntu-24.04"], }) is Some(_),
  )
  assert_true(
    validate_definition({ ..debian, labels: ["windows"], }) is Some(_),
  )
  assert_true(
    validate_definition({ ..debian, labels: ["windows-2025"], }) is Some(_),
  )
  assert_true(validate_definition({ ..debian, name: "macos-15", }) is Some(_))
  assert_eq(validate_definition({ ..ubuntu, labels: ["ubuntu-latest"], }), None)
  assert_eq(debian.effective_labels(), ["debian-12", "x64", "debian"])
}

///|
test "distribution checks verify exact userspace version and architecture" {
  let debian = definition("debian", "debian-12")
  assert_true(
    debian.matches_system("ID=debian\nVERSION_ID=\"12\"\n", "x86_64\n"),
  )
  assert_false(
    debian.matches_system("ID=ubuntu\nVERSION_ID=\"24.04\"\n", "x86_64"),
  )
  assert_false(debian.matches_system("ID=debian\nVERSION_ID=13\n", "amd64"))
  assert_false(debian.matches_system("ID=debian\nVERSION_ID=12\n", "aarch64"))
  assert_false(debian.matches_system("", "x64"))
}
