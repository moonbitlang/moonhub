///|
let test_ssh_addresses : SshAddressConfig = {
  public_override: Some({ host: "git.example.com", port: 12222, }),
  internal: Some({ host: "ssh", port: 2222, }),
}

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
      BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted invalid endpoint: \{value}")
    }
  }
}

///|
async test "SSH site settings require admin access and session-bound CSRF" {
  with_ssh_settings_app((port, pool, alice, _, admin) => {
    let (anonymous, _) = http_get_path(port, "/-/admin/settings/ssh")
    assert_eq(anonymous.code, 303)
    let (denied, _) = http_get_path_with_cookie(
      port, "/-/admin/settings/ssh", alice,
    )
    assert_eq(denied.code, 403)
    let (page, body) = http_get_path_with_cookie(
      port, "/-/admin/settings/ssh", admin,
    )
    assert_eq(page.code, 200)
    assert_true(page.headers.get("cache-control") is Some("no-store"))
    let token = extract_attr(body, "name=\"csrf_token\"", "value=\"")
    let wrong_scope = settings_form_token(port, admin)
    for csrf in ["", "forged", wrong_scope] {
      let (rejected, _) = http_post_path_with_cookie(
        port,
        "/-/admin/settings/ssh",
        "csrf_token=\{csrf}&host=git.example.com&port=12222",
        admin,
      )
      assert_eq(rejected.code, 403)
    }
    let (forbidden, _) = http_post_path_with_cookie(
      port,
      "/-/admin/settings/ssh",
      "csrf_token=\{token}&host=git.example.com&port=12222",
      alice,
    )
    assert_eq(forbidden.code, 403)
    assert_true(effective_ssh_endpoint(pool, no_ssh_address_config) is None)
    let (invalid, _) = http_post_path_with_cookie(
      port,
      "/-/admin/settings/ssh",
      "csrf_token=\{token}&host=0.0.0.0&port=22",
      admin,
    )
    assert_eq(invalid.code, 400)
    let (saved, _) = http_post_path_with_cookie(
      port,
      "/-/admin/settings/ssh",
      "csrf_token=\{token}&host=Git.Example.com&port=12222",
      admin,
    )
    assert_eq(saved.code, 303)
    assert_eq(
      effective_ssh_endpoint(pool, no_ssh_address_config).unwrap().authority(),
      "git.example.com:12222",
    )
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let cross_site = client.post(
      "/-/admin/settings/ssh",
      "csrf_token=\{token}&host=other.example&port=22",
      extra_headers={
        "Cookie": "\{admin.name}=\{admin.value}",
        "Sec-Fetch-Site": "cross-site",
        "Content-Type": "application/x-www-form-urlencoded",
      },
    )
    client.skip_response_body()
    assert_eq(cross_site.code, 403)
  })
}

///|
async test "clone URLs use live site configuration and never request host headers" {
  with_ssh_settings_app((port, pool, alice, _, _) => {
    let (_, initial) = http_get_path_with_cookie(port, "/alice/demo", alice)
    assert_true(initial.contains("SSH clone address is not configured."))
    assert_true(!initial.contains("data-clone-url"))
    let admin = active_user_by_name(pool, "admin")
    save_ssh_endpoint(
      pool, admin, no_ssh_address_config, "git.example.com", "12222",
    )
    let (_, configured) = http_get_path_with_cookie(port, "/alice/demo", alice)
    assert_true(
      configured.contains("ssh://git@git.example.com:12222/alice/demo.git"),
    )
    assert_true(configured.contains("data-clone-copy"))
    assert_true(!configured.contains("aria-label=\"Site settings\""))
    save_ssh_endpoint(
      pool, admin, no_ssh_address_config, "new.example.com", "22",
    )
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let response = client.get("/alice/demo", extra_headers={
      "Cookie": "\{alice.name}=\{alice.value}",
      "Host": "forged.example",
      "X-Forwarded-Host": "forged.example",
    })
    let body = client.read_all().text()
    assert_eq(response.code, 200)
    assert_true(body.contains("ssh://git@new.example.com:22/alice/demo.git"))
    assert_true(!body.contains("forged.example"))
  })
}

///|
async test "deployment SSH endpoint override is visible readonly and authoritative" {
  with_ssh_settings_app(
    (port, pool, alice, _, admin_cookie) => {
      let admin = active_user_by_name(pool, "admin")
      save_ssh_endpoint(
        pool, admin, no_ssh_address_config, "saved.example", "22",
      )
      assert_eq(
        effective_ssh_endpoint(pool, test_ssh_addresses).unwrap().authority(),
        "git.example.com:12222",
      )
      let (_, body) = http_get_path_with_cookie(
        port, "/-/admin/settings/ssh", admin_cookie,
      )
      assert_true(body.contains("Managed by deployment configuration"))
      assert_true(body.contains("class=\"ssh-address-fields\" disabled"))
      assert_true(body.contains("ssh://git@ssh:2222"))
      let token = extract_attr(body, "name=\"csrf_token\"", "value=\"")
      let (locked, _) = http_post_path_with_cookie(
        port,
        "/-/admin/settings/ssh",
        "csrf_token=\{token}&host=other.example&port=22",
        admin_cookie,
      )
      assert_eq(locked.code, 403)
      assert_eq(
        effective_ssh_endpoint(pool, no_ssh_address_config).unwrap().authority(),
        "saved.example:22",
      )
      let (_, repo) = http_get_path_with_cookie(port, "/alice/demo", alice)
      assert_true(
        repo.contains("ssh://git@git.example.com:12222/alice/demo.git"),
      )
      assert_true(!repo.contains("ssh://git@ssh:2222"))
    },
    addresses=test_ssh_addresses,
  )
}

///|
async test "own-instance imports require source read permission on public and internal addresses" {
  with_ssh_test_db(pool => {
    let alice = active_user_by_name(pool, "alice")
    let bob = active_user_by_name(pool, "bob")
    for
      url in [
        "ssh://git@git.example.com:12222/alice/demo.git", "ssh://git@ssh:2222/alice/demo.git",
      ] {
      let source = resolve_repository_import_source(
        pool, alice, url, test_ssh_addresses,
      )
      assert_true(source.local_id is Some(1L))
      assert_eq(source.transport.url, "ssh://git@ssh:2222/alice/demo.git")
      try
        resolve_repository_import_source(pool, bob, url, test_ssh_addresses)
      catch {
        NotFound(_) => ()
        Forbidden(_) => ()
        err => raise err
      } noraise {
        _ => fail("private source accessible to another user")
      }
    }
    let public_source = resolve_repository_import_source(
      pool, bob, "ssh://git@git.example.com:12222/alice/public.git", test_ssh_addresses,
    )
    assert_true(public_source.local_id is Some(2L))
    for
      url in [
        "ssh://git@git.example.com:22/alice/demo.git", "ssh://git@git.example.com.other:12222/alice/demo.git",
      ] {
      let external = resolve_repository_import_source(
        pool, bob, url, test_ssh_addresses,
      )
      assert_true(external.local_id is None)
      assert_eq(external.transport.url, url)
    }
  })
}

///|
async test "queued local imports keep source identity across public address changes" {
  with_repository_test_app((_, pool, root, _, _) => {
    let alice = active_user_by_name(pool, "alice")
    let admin = active_user_by_name(pool, "admin")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    let addresses : SshAddressConfig = {
      public_override: None,
      internal: test_ssh_addresses.internal,
    }
    save_ssh_endpoint(pool, admin, addresses, "git.example.com", "12222")
    ignore(
      enqueue_repository(
        pool,
        root,
        alice,
        team,
        "local-copy",
        "private",
        "ssh://git@git.example.com:12222/alice/demo.git",
        addresses~,
      ),
    )
    let job = require_repository_job(pool, team, "local-copy")
    assert_eq(job.source_kind, "local")
    assert_true(job.source_repository_id is Some(1L))
    save_ssh_endpoint(pool, admin, addresses, "changed.example", "22")
    assert_eq(
      repository_job_source(pool, alice, job, addresses).unwrap().url,
      "ssh://git@ssh:2222/alice/demo.git",
    )
    let config = mock_import_config(root, "\{root}/alice/demo.git")
    @fs.write_file(
      "\{config.credentials_root}/alice/allowed_hosts",
      "ssh:2222\n",
      permission=0o600,
    )
    assert_true(run_next_repository_job(pool, root, Some(config), addresses~))
    assert_eq(
      require_repository_job(pool, team, "local-copy").status,
      "succeeded",
    )
    assert_true(
      can_access_repository(
        pool,
        alice,
        { owner: "alice", name: "local-copy", },
        Read,
      ),
    )
  })
}

///|
async test "local import fails closed after source deletion even if its path is reused" {
  with_repository_test_app((_, pool, root, _, _) => {
    let alice = active_user_by_name(pool, "alice")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    ignore(
      enqueue_repository(
        pool,
        root,
        alice,
        team,
        "deleted-copy",
        "private",
        "ssh://git@git.example.com:12222/alice/demo.git",
        addresses=test_ssh_addresses,
      ),
    )
    pool.with_client(client => {
      client.batch_execute(
        "DELETE FROM repository WHERE id = 1; INSERT INTO repository (team_id, name, visibility) VALUES (1, 'demo', 'private');",
      )
    })
    let job = require_repository_job(pool, team, "deleted-copy")
    assert_eq(job.source_kind, "local")
    assert_true(job.source_repository_id is None)
    assert_true(
      run_next_repository_job(pool, root, None, addresses=test_ssh_addresses),
    )
    assert_eq(
      require_repository_job(pool, team, "deleted-copy").status,
      "failed",
    )
    assert_true(!@fs.exists("\{root}/alice/deleted-copy.git"))
  })
}

///|
async test "source permission revocation blocks queued local import" {
  with_repository_test_app((_, pool, root, _, _) => {
    let bob = active_user_by_name(pool, "bob")
    let team = get_team_by_name_key(pool, "bob").unwrap()
    ignore(
      enqueue_repository(
        pool,
        root,
        bob,
        team,
        "revoked-copy",
        "private",
        "ssh://git@git.example.com:12222/alice/public.git",
        addresses=test_ssh_addresses,
      ),
    )
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository SET visibility = 'private' WHERE id = 2",
      )
    })
    assert_true(
      run_next_repository_job(pool, root, None, addresses=test_ssh_addresses),
    )
    assert_eq(
      require_repository_job(pool, team, "revoked-copy").status,
      "failed",
    )
    assert_true(!@fs.exists("\{root}/bob/revoked-copy.git"))
  })
}

///|
async test "external jobs stay external while legacy jobs are checked and pinned" {
  with_repository_test_app((_, pool, root, _, _) => {
    let alice = active_user_by_name(pool, "alice")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    let url = "ssh://git@git.example.com:12222/alice/demo.git"
    ignore(
      enqueue_repository(
        pool, root, alice, team, "external-copy", "private", url,
      ),
    )
    let external = require_repository_job(pool, team, "external-copy")
    assert_eq(external.source_kind, "external")
    assert_eq(
      repository_job_source(pool, alice, external, test_ssh_addresses).unwrap().url,
      url,
    )
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository_job SET source_kind = 'legacy' WHERE repository_id = ?",
        params=[external.id],
      )
    })
    let legacy = require_repository_job(pool, team, "external-copy")
    let pinned = pin_legacy_repository_source(
      pool, alice, legacy, test_ssh_addresses,
    )
    assert_eq(pinned.source_kind, "local")
    assert_true(pinned.source_repository_id is Some(1L))
    assert_eq(
      require_repository_job(pool, team, "external-copy").source_kind,
      "local",
    )
    assert_eq(
      repository_job_source(pool, alice, pinned, test_ssh_addresses).unwrap().url,
      "ssh://git@ssh:2222/alice/demo.git",
    )
  })
}

///|
async test "SSH address migration preserves version two jobs as legacy" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    let baseline = @fs.read_file("db/base.sql").text()
    let ssh = @fs.read_file("db/migrations/001_ssh_keys.sql").text()
    let jobs = @fs.read_file("db/migrations/002_repository_jobs.sql").text()
    pool.with_client(client => {
      client.batch_execute(baseline)
      client.batch_execute(ssh)
      client.batch_execute(jobs)
      client.batch_execute(
        (
          #|INSERT INTO "user" (id, name_key, display_name, password_hash, is_site_admin) VALUES (1, 'alice', 'Alice', 'test', 0);
          #|INSERT INTO team (id, name_key, display_name, kind) VALUES (1, 'alice', 'Alice', 'personal');
          #|INSERT INTO repository (id, team_id, name, visibility, ready) VALUES (1, 1, 'copy', 'private', 0);
          #|INSERT INTO repository_job (repository_id, requested_by_user_id, source_url) VALUES (1, 1, 'git@source.example:repo.git');
          #|PRAGMA user_version = 2;
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    let job = require_repository_job(
      pool,
      get_team_by_name_key(pool, "alice").unwrap(),
      "copy",
    )
    assert_eq(job.source_kind, "legacy")
    assert_true(job.source_repository_id is None)
    assert_eq(job.source_url, "git@source.example:repo.git")
    assert_true(effective_ssh_endpoint(pool, no_ssh_address_config) is None)
  })
}
