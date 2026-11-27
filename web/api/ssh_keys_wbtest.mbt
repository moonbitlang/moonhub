///|
async test "SSH key API requires its own token permission and scopes keys to the account" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let token = @identity.create_access_token(pool, alice, "ssh", "ssh", 1)
    let outsider = @identity.create_access_token(pool, admin, "ssh", "ssh", 1)
    let endpoint = "/user/ssh-keys"
    let body : Json = {
      "title": "Laptop",
      "public_key": @test_support.test_ssh_public_key,
    }
    assert_eq(api_test_request(port, endpoint, "", None).0, 401)
    for permission in ["read", "write", "execute", "merge"] {
      let other = @identity.create_access_token(
        pool, alice, permission, permission, 1,
      )
      assert_eq(api_test_request(port, endpoint, other, None).0, 403)
      assert_eq(api_test_request(port, endpoint, other, Some(body)).0, 403)
    }
    assert_eq(api_test_request(port, "/user", token, None).0, 200)
    assert_eq(
      api_test_request(
        port,
        "/repos",
        token,
        Some({ "owner": "alice", "name": "denied" }),
      ).0,
      403,
    )
    assert_eq(
      api_test_request(
        port,
        endpoint,
        token,
        Some({ "title": "Invalid", "public_key": "invalid" }),
      ).0,
      400,
    )
    let (status, created) = api_test_request(port, endpoint, token, Some(body))
    assert_eq(status, 200)
    guard created
      is {
        "id": String(id),
        "title": String("Laptop"),
        "fingerprint": String(fingerprint),
        ..
      } else {
      fail("missing created key details")
    }
    assert_true(fingerprint.has_prefix("SHA256:"))
    assert_eq(api_test_request(port, endpoint, token, Some(body)).0, 400)
    let (_, keys) = api_test_request(port, endpoint, token, None)
    assert_true(
      keys is { "items": [{ "id": String(found), "revoked_at": Null, .. }], .. } &&
      found == id,
    )
    let (_, other_keys) = api_test_request(port, endpoint, outsider, None)
    assert_true(other_keys is { "items": [], .. })
    let revoke = "\{endpoint}/\{id}/revoke"
    let empty = Some(Json::empty_object())
    assert_eq(api_test_request(port, revoke, outsider, empty).0, 404)
    let (status, revoked) = api_test_request(port, revoke, token, empty)
    assert_eq(status, 200)
    assert_true(
      revoked is { "id": String(found), "revoked": True, .. } && found == id,
    )
    assert_eq(api_test_request(port, revoke, token, empty).0, 404)
    let (_, keys) = api_test_request(port, endpoint, token, None)
    assert_true(
      keys
      is { "items": [{ "id": String(found), "revoked_at": String(_), .. }], .. } &&
      found == id,
    )
  })
}

///|
async test "SSH key enrollment rechecks a token revoked during the request body" {
  let started = @async.Semaphore(1, initial_value=0)
  @web_testkit.with_repository_test_app(
    (port, pool, _, _, _) => {
      let alice = @identity.active_user_by_name(pool, "alice")
      let token = @identity.create_access_token(pool, alice, "ssh", "ssh", 1)
      let payload : Json = {
        "title": "Laptop",
        "public_key": @test_support.test_ssh_public_key,
      }
      let (response, _) = @web_testkit.partial_body_request(
        port,
        "/-/api/v1/user/ssh-keys",
        payload.stringify(),
        {
          "Content-Type": "application/json",
          "Authorization": "Bearer " + token,
        },
        started,
        () => {
          @identity.revoke_access_token(
            pool,
            alice,
            @identity.access_tokens(pool, alice)[0].id,
          )
        },
      )
      assert_eq(response.code, 401)
      assert_true(@ssh.user_ssh_keys(pool, alice).is_empty())
    },
    body_read_started=started,
  )
}
