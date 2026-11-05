///|
test "Tart image policy allows pinned remote digests and explicit local templates only" {
  assert_true(valid_vm_image("ghcr.io/example/macos@sha256:" + "a".repeat(64)))
  assert_true(valid_vm_image("local:moonhub-macos-v1"))
  for
    image in [
      "latest", "ghcr.io/example/macos:latest", "local:../template", "local:moonhub-slot-test",
      "local:-x", "local:", "local:.", "local:..",
    ] {
    assert_true(!valid_vm_image(image))
  }
}

///|
test "Tart cleanup inventory is limited to owned slot names" {
  let name = "moonhub-slot-" + "a".repeat(32)
  assert_eq(
    vm_names("[{\"Name\":\"other-template\"},{\"Name\":\"" + name + "\"}]"),
    [name],
  )
  try ignore(vm_names("[{\"Name\":\"moonhub-slot-../escape\"}]")) catch {
    InvalidConfiguration(_) => ()
    err => raise err
  } noraise {
    _ => fail("Accepted unsafe VM identity")
  }
}

///|
test "Mac template readiness rejects Linux running and suspended disks" {
  validate_vm_template("{\"OS\":\"darwin\",\"State\":\"stopped\"}")
  for
    template in [
      "{\"OS\":\"linux\",\"State\":\"stopped\"}", "{\"OS\":\"darwin\",\"State\":\"running\"}",
      "{\"OS\":\"darwin\",\"State\":\"suspended\"}",
    ] {
    try validate_vm_template(template) catch {
      InvalidConfiguration(_) => ()
      err => raise err
    } noraise {
      _ => fail("Accepted unsafe Mac template")
    }
  }
}
