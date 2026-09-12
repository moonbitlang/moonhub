///|
let test_ssh_public_key : String = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB"

///|
async fn with_ssh_test_db(f : async (Database) -> Unit) -> Unit {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    initialize_db(pool)
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user" (id, name_key, display_name, password_hash, is_site_admin)
          #|VALUES (1, 'alice', 'Alice', 'test', 0), (2, 'bob', 'Bob', 'test', 0),
          #|  (3, 'admin', 'Admin', 'test', 1);
          #|INSERT INTO team (id, name_key, display_name, kind)
          #|VALUES (1, 'alice', 'Alice', 'personal'), (2, 'bob', 'Bob', 'personal');
          #|INSERT INTO team_member (team_id, user_id, role)
          #|VALUES (1, 1, 'owner'), (2, 2, 'owner');
          #|INSERT INTO repository (team_id, name, visibility)
          #|VALUES (1, 'demo', 'private'), (1, 'public', 'public');
        ),
      )
    })
    f(pool)
  })
}

///|
test "SSH keys normalize comments and whitespace and reject injected options" {
  let plain = parse_ssh_public_key(test_ssh_public_key)
  let decorated = parse_ssh_public_key("  \{test_ssh_public_key}\tlaptop\n")
  assert_eq(plain.public_key, decorated.public_key)
  assert_eq(plain.fingerprint, decorated.fingerprint)
  assert_true(plain.fingerprint.has_prefix("SHA256:"))
  assert_true(!plain.fingerprint.has_suffix("="))
  for
    invalid in [
      "command=\"id\" \{test_ssh_public_key}",
      "\{test_ssh_public_key}\n\{test_ssh_public_key}",
      "ssh-ed25519 !!!",
      "ssh-ed25519 YWJj",
      "ssh-rsa YWJj",
      "",
    ] {
    try parse_ssh_public_key(invalid) catch {
      BadRequest(_) => ()
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
  assert_true(fetch.operation is Read)
  let push = parse_ssh_request("git-receive-pack '/alice/demo.git'")
  assert_eq(push.repo.path(), "alice/demo")
  assert_true(push.operation is Write)
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
      BadRequest(_) => ()
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
async test "SSH migration upgrades existing databases and is repeatable" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    let baseline = @fs.read_file("db/base.sql").text()
    pool.with_client(client => {
      client.batch_execute(baseline)
      let _ = client.execute(
        "INSERT INTO team (name_key, display_name, kind) VALUES ('existing', 'Existing', 'org')",
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_true(
        client.query_opt("SELECT id FROM team WHERE name_key = 'existing'")
        is Some(_),
      )
      assert_true(
        client.query_opt(
          "SELECT name FROM sqlite_master WHERE name = 'ssh_key'",
        )
        is Some(_),
      )
      let row = client.query_opt("PRAGMA user_version").unwrap()
      let version : Int64 = row.get_name("user_version")
      assert_eq(version, 1L)
    })
  })
}

///|
async test "repository access is consistent for private public admin and disabled users" {
  with_ssh_test_db(pool => {
    let alice = active_user_by_name(pool, "alice")
    let bob = active_user_by_name(pool, "bob")
    let admin = active_user_by_name(pool, "admin")
    let private_repo : RepoId = { owner: "alice", name: "demo", }
    let public_repo : RepoId = { owner: "alice", name: "public", }
    assert_true(can_access_repository(pool, alice, private_repo, Read))
    assert_true(can_access_repository(pool, alice, private_repo, Write))
    assert_true(!can_access_repository(pool, bob, private_repo, Read))
    assert_true(!can_access_repository(pool, bob, private_repo, Write))
    assert_true(can_access_repository(pool, bob, public_repo, Read))
    assert_true(!can_access_repository(pool, bob, public_repo, Write))
    assert_true(can_access_repository(pool, admin, private_repo, Write))
    assert_true(
      !can_access_repository(
        pool,
        admin,
        { owner: "alice", name: "unknown", },
        Read,
      ),
    )
    pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
      )
    })
    assert_true(can_access_repository(pool, bob, private_repo, Write))
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET status = 'disabled' WHERE id = 2",
      )
    })
    assert_true(!can_access_repository(pool, bob, public_repo, Read))
    assert_true(!can_access_repository(pool, bob, private_repo, Write))
  })
}

///|
async test "revoked or disabled SSH identities cannot authenticate or open another channel" {
  with_ssh_test_db(pool => {
    let alice = active_user_by_name(pool, "alice")
    let key = parse_ssh_public_key(test_ssh_public_key)
    let id = add_ssh_key(pool, alice, "Laptop", key)
    assert_eq(ssh_key_user(pool, id).id, alice.id)
    assert_true(
      authorized_ssh_key(pool, key)
      .unwrap()
      .has_prefix("restrict,command=\"/usr/local/bin/moonhub ssh-serve "),
    )
    try
      add_ssh_key(pool, active_user_by_name(pool, "bob"), "Duplicate", key)
    catch {
      BadRequest(_) => ()
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
      Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("revoked key opened another session")
    }
  })
}

///|
async test "repository paths reject symlink aliases into another namespace" {
  with_git_test_repo((root, git_dir) => {
    assert_eq(
      resolve_repository_dir(root, { owner: "alice", name: "demo", }),
      @fs.realpath(git_dir),
    )
    @fs.mkdir("\{root}/bob")
    @fs.symlink(target=git_dir, "\{root}/bob/stolen.git")
    try resolve_repository_dir(root, { owner: "bob", name: "stolen", }) catch {
      NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted cross-namespace symlink")
    }
  })
}

///|
test "management commands inherit deployment settings and parse key identifiers" {
  let parsed = management_command().parse(
    argv=["repo-create", "alice/demo", "--import", "--visibility", "public"],
    env={ "DB_PATH": "/data/moonhub.db", "MOONHUB_REPO_ROOT": "/data/repos" },
  )
  assert_eq(cli_value(parsed, "db"), "/data/moonhub.db")
  assert_eq(cli_value(parsed, "root"), "/data/repos")
  let (_, options) = parsed.subcommand.unwrap()
  assert_eq(cli_value(options, "repository"), "alice/demo")
  assert_true(options.flags["import"])
  assert_eq(cli_value(options, "visibility"), "public")
}

///|
async test "create and import register only managed bare repositories" {
  with_ssh_test_db(pool => {
    with_git_test_repo((root, _) => {
      create_managed_repository(
        pool,
        root,
        { owner: "bob", name: "new", },
        "private",
        false,
      )
      assert_true(@fs.exists("\{root}/bob/new.git/HEAD"))
      assert_eq(default_ref("\{root}/bob/new.git"), "main")
      assert_true(
        can_access_repository(
          pool,
          active_user_by_name(pool, "bob"),
          { owner: "bob", name: "new", },
          Write,
        ),
      )
      pool.with_client(client => {
        let _ = client.execute("DELETE FROM repository WHERE name = 'demo'")
      })
      create_managed_repository(
        pool,
        root,
        { owner: "alice", name: "demo", },
        "private",
        true,
      )
      assert_eq(list_commits("\{root}/alice/demo.git", "master").length(), 1)
    })
  })
}

///|
async test "production browser hides unregistered and unauthorized repositories" {
  with_production_test_app((_, port, pool) => {
    let key = hash_password("sshBrowserPassword")
    pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO \"user\" (name_key, display_name, password_hash) VALUES ('ssh_browser', 'Browser', ?)",
        params=[key],
      )
      let _ = client.execute(
        "INSERT INTO team (name_key, display_name, kind) VALUES ('alice', 'Alice', 'personal')",
      )
      let _ = client.execute(
        "INSERT INTO repository (team_id, name, visibility) SELECT id, 'demo', 'private' FROM team WHERE name_key = 'alice'",
      )
    })
    let cookie = login_test_user(port, "ssh_browser", "sshBrowserPassword")
    let (index_response, index) = http_get_path_with_cookie(port, "/", cookie)
    assert_eq(index_response.code, 200)
    assert_true(!index.contains("alice/demo"))
    let (denied, _) = http_get_path_with_cookie(port, "/alice/demo", cookie)
    assert_eq(denied.code, 404)
    pool.with_client(client => {
      let _ = client.execute("UPDATE repository SET visibility = 'public'")
    })
    let (allowed, _) = http_get_path_with_cookie(port, "/alice/demo", cookie)
    assert_eq(allowed.code, 200)
    pool.with_client(client => {
      let _ = client.execute("DELETE FROM repository")
    })
    let (unregistered, _) = http_get_path_with_cookie(
      port, "/alice/demo", cookie,
    )
    assert_eq(unregistered.code, 404)
  })
}

///|
async test "new empty repositories have browsable files and commits pages" {
  with_ssh_test_db(pool => {
    let root = @fs.tmpdir(prefix="moonhub-empty-")
    defer @fs.rmdir(root, recursive=true)
    create_managed_repository(
      pool,
      root,
      { owner: "alice", name: "empty", },
      "private",
      false,
    )
    let token = pool.with_client(client => {
      client.with_transaction(tx => create_session_token(tx, 1L))
    })
    let app = @moonback.App(
      app_module,
      config=Config(custom=[
        @moonback.Config::custom(config_root, root),
        @moonback.Config::custom(config_assets_root, test_assets_root),
        @moonback.Config::custom(config_db_pool, pool),
      ]),
    )
    defer app.close()
    @async.with_task_group(group => {
      let listener = @moonback.listen(port=0)
      let server = group.spawn(() => app.serve(listener))
      defer server.cancel()
      let cookie = session_cookie(token)
      let (files, files_body) = http_get_path_with_cookie(
        listener.addr.port(),
        "/alice/empty",
        cookie,
      )
      assert_eq(files.code, 200)
      assert_true(files_body.contains("No files."))
      let (commits, commits_body) = http_get_path_with_cookie(
        listener.addr.port(),
        "/alice/empty/commits",
        cookie,
      )
      assert_eq(commits.code, 200)
      assert_true(commits_body.contains("No commits."))
      let (invalid, _) = http_get_path_with_cookie(
        listener.addr.port(),
        "/alice/empty/tree/missing",
        cookie,
      )
      assert_eq(invalid.code, 404)
    })
  })
}
