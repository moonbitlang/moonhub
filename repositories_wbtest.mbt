///|
async fn with_repository_test_app(
  f : async (Int, Database, String, @http.Cookie, @http.Cookie) -> Unit,
) -> Unit {
  with_ssh_test_db(pool => {
    with_git_test_repo((root, _) => {
      let cookies = pool.with_client(client => {
        client.with_transaction(tx => {
          [1L, 2L].map(id => session_cookie(create_session_token(tx, id)))
        })
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
        f(listener.addr.port(), pool, root, cookies[0], cookies[1])
      })
    })
  })
}

///|
async fn repository_test_token(
  port : Int,
  team : String,
  cookie : @http.Cookie,
) -> String {
  let (response, body) = http_get_path_with_cookie(
    port,
    "/teams/\{team}/repositories/new",
    cookie,
  )
  assert_eq(response.code, 200)
  extract_attr(body, "name=\"csrf_token\"", "value=\"")
}

///|
async fn mock_import_config(root : String, source : String) -> RepoImportConfig {
  let credentials = "\{root}/credentials"
  @fs.mkdir("\{credentials}/alice", recursive=true, permission=0o700)
  @fs.write_file(
    "\{credentials}/alice/id_ed25519",
    "fixture identity",
    permission=0o600,
  )
  @fs.write_file(
    "\{credentials}/alice/known_hosts",
    "fixture known host",
    permission=0o600,
  )
  @fs.write_file(
    "\{credentials}/alice/allowed_hosts",
    "source.example:22\n",
    permission=0o600,
  )
  let wrapper = "\{root}/fixture-ssh"
  @fs.write_file(
    wrapper,
    "#!/bin/sh\nexec git upload-pack '\{source}'\n",
    permission=0o700,
  )
  // Functional imports share the async executor with CPU-heavy authentication
  // tests. Deadline behavior has its own test with an explicit short timeout.
  { credentials_root: credentials, ssh_wrapper: wrapper, timeout_ms: 300000, }
}

///|
test "SSH import parsing preserves relative scp paths and validates transport arguments" {
  let scp = parse_ssh_import_source("git@Git.Example.com:group/sub/repo.git")
  assert_eq(scp.url, "git@git.example.com:group/sub/repo.git")
  assert_eq(scp.host, "git.example.com")
  assert_eq(scp.port, 22)
  let uri = parse_ssh_import_source(
    "ssh://git@git.example.com:2222/group/repo.git",
  )
  assert_eq(uri.url, "ssh://git@git.example.com:2222/group/repo.git")
  assert_eq(uri.port, 2222)
  for
    value in [
      "https://git.example/repo.git", "file:///etc/passwd", "ext::sh -c id", "git@host:-repo.git",
      "git@host:../repo.git", "git@host:group/../repo.git", "ssh://git:password@host/repo.git",
      "ssh://-oProxyCommand=sh@host/repo.git", "ssh://git@-host/repo.git", "ssh://git@host:0/repo.git",
      "ssh://git@host:65536/repo.git", "git@host:repo.git;id", "git@host:repo$(id).git",
      "git@host:group/%2e%2e/repo.git", "git@host:repo.git\n", "ssh://host/repo.git",
      "ssh://git@host//repo.git",
    ] {
    try parse_ssh_import_source(value) catch {
      BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted unsafe source: \{value}")
    }
  }
}

///|
async test "team import identities reject symlinks and disallowed source ports" {
  with_git_test_repo((root, source) => {
    let config = mock_import_config(root, source)
    let credentials = team_import_credentials(config, "alice")
    authorize_import_source(
      credentials,
      parse_ssh_import_source("git@source.example:repo.git"),
    )
    try
      authorize_import_source(
        credentials,
        parse_ssh_import_source("ssh://git@source.example:2222/repo.git"),
      )
    catch {
      BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("allowed an unlisted SSH port")
    }
    @fs.remove("\{config.credentials_root}/alice/known_hosts")
    @fs.symlink(
      target="\{source}/HEAD",
      "\{config.credentials_root}/alice/known_hosts",
    )
    try team_import_credentials(config, "alice") catch {
      BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("followed an import credential symlink")
    }
  })
}

///|
async test "team owners create private repositories without exposing partially prepared data" {
  with_repository_test_app((port, pool, root, alice_cookie, _) => {
    let csrf = repository_test_token(port, "alice", alice_cookie)
    let (response, _) = http_post_path_with_cookie(
      port,
      "/teams/alice/repositories",
      "csrf_token=\{csrf}&name=new-repo&visibility=private&team=bob",
      alice_cookie,
    )
    assert_eq(response.code, 303)
    assert_true(
      response.headers.get("location")
      is Some("/teams/alice/repositories/new-repo/status"),
    )
    let alice = active_user_by_name(pool, "alice")
    let repo : RepoId = { owner: "alice", name: "new-repo", }
    assert_true(!@fs.exists(repo.git_dir(root)))
    assert_true(!can_access_repository(pool, alice, repo, Read))
    let (pending, _) = http_get_path_with_cookie(
      port, "/teams/alice/repositories/new-repo/status", alice_cookie,
    )
    assert_eq(pending.code, 200)
    assert_true(pending.headers.get("refresh") is Some("2"))
    assert_true(run_next_repository_job(pool, root, None))
    assert_true(can_access_repository(pool, alice, repo, Write))
    assert_eq(default_ref(repo.git_dir(root)), "main")
    let (ready, _) = http_get_path_with_cookie(
      port, "/teams/alice/repositories/new-repo/status", alice_cookie,
    )
    assert_eq(ready.code, 303)
    assert_true(ready.headers.get("location") is Some("/alice/new-repo"))
    let (team_response, team_body) = http_get_path_with_cookie(
      port, "/teams/alice", alice_cookie,
    )
    assert_eq(team_response.code, 200)
    assert_true(team_body.contains("New repository"))
    assert_true(team_body.contains("/alice/new-repo"))
    assert_true(!run_next_repository_job(pool, root, None))
  })
}

///|
async test "team repository creation denies outsiders ordinary members and forged CSRF tokens" {
  with_repository_test_app((port, pool, _, alice, bob) => {
    let csrf = repository_test_token(port, "alice", alice)
    let (outsider, _) = http_post_path_with_cookie(
      port,
      "/teams/alice/repositories",
      "csrf_token=\{csrf}&name=stolen",
      bob,
    )
    assert_eq(outsider.code, 401)
    pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
      )
    })
    let (member_response, _) = http_get_path_with_cookie(
      port, "/teams/alice/repositories/new", bob,
    )
    assert_eq(member_response.code, 403)
    let (missing, _) = http_post_path_with_cookie(
      port, "/teams/alice/repositories", "name=invalid", alice,
    )
    assert_eq(missing.code, 403)
    let settings_csrf = settings_form_token(port, alice)
    let (wrong_scope, _) = http_post_path_with_cookie(
      port,
      "/teams/alice/repositories",
      "csrf_token=\{settings_csrf}&name=invalid",
      alice,
    )
    assert_eq(wrong_scope.code, 403)
    let (unconfigured, _) = http_post_path_with_cookie(
      port,
      "/teams/alice/repositories/import",
      "csrf_token=\{csrf}&name=imported&source_url=git@source.example:repo.git",
      alice,
    )
    assert_eq(unconfigured.code, 400)
  })
}

///|
async test "concurrent creation reserves a name once and never reinitializes existing data" {
  with_repository_test_app((port, pool, root, alice, _) => {
    let csrf = repository_test_token(port, "alice", alice)
    let results = @async.all([
      () => {
        http_post_path_with_cookie(
          port,
          "/teams/alice/repositories",
          "csrf_token=\{csrf}&name=unique",
          alice,
        )
      },
      () => {
        http_post_path_with_cookie(
          port,
          "/teams/alice/repositories",
          "csrf_token=\{csrf}&name=unique",
          alice,
        )
      },
    ])
    assert_true(
      (results[0].0.code == 303 && results[1].0.code == 400) ||
      (results[1].0.code == 303 && results[0].0.code == 400),
    )
    let head = @fs.read_file("\{root}/alice/demo.git/HEAD").text()
    let (duplicate, _) = http_post_path_with_cookie(
      port,
      "/teams/alice/repositories",
      "csrf_token=\{csrf}&name=demo",
      alice,
    )
    assert_eq(duplicate.code, 400)
    assert_eq(@fs.read_file("\{root}/alice/demo.git/HEAD").text(), head)
    assert_true(run_next_repository_job(pool, root, None))
    assert_true(!run_next_repository_job(pool, root, None))
  })
}

///|
async test "SSH import failure cleans staging and retry preserves branches tags and default branch" {
  with_repository_test_app((_, pool, root, _, _) => {
    let source = "\{root}/alice/demo.git"
    ignore(run_git(source, ["branch", "feature/demo", "master"]))
    ignore(run_git(source, ["tag", "v1", "master"]))
    let alice = active_user_by_name(pool, "alice")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    let repo = enqueue_repository(
      pool, root, alice, team, "imported", "private", "git@source.example:group/repo.git",
    )
    assert_true(run_next_repository_job(pool, root, None))
    let failed = require_repository_job(pool, team, repo.name)
    assert_eq(failed.status, "failed")
    assert_true(!@fs.exists(repo.git_dir(root)))
    assert_eq(@fs.readdir("\{root}/.imports").length(), 1)
    let config = mock_import_config(root, source)
    retry_repository_job(pool, alice, team, repo.name)
    assert_true(run_next_repository_job(pool, root, Some(config)))
    let completed = require_repository_job(pool, team, repo.name)
    assert_eq(
      completed.status,
      "succeeded",
      msg=completed.last_error.unwrap_or("import failed without a diagnostic"),
    )
    assert_eq(completed.attempt_count, 2L)
    assert_eq(default_ref(repo.git_dir(root)), "master")
    let refs = ["for-each-ref", "--format=%(refname):%(objectname)"]
    assert_eq(run_git(repo.git_dir(root), refs), run_git(source, refs))
    assert_eq(run_git(repo.git_dir(root), ["remote"]), "")
    assert_true(can_access_repository(pool, alice, repo, Read))
  })
}

///|
async test "interrupted repository jobs recover publication and honor the worker lock" {
  with_repository_test_app((_, pool, root, _, _) => {
    let alice = active_user_by_name(pool, "alice")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    let repo = enqueue_repository(
      pool, root, alice, team, "recovered", "private", "",
    )
    let job = require_repository_job(pool, team, repo.name)
    let work = repository_work_directory(root)
    let lock = @fs.open(
      "\{work}/worker.lock",
      mode=ReadWrite,
      create_mode=OpenOrCreate,
    )
    assert_true(lock.try_lock(Exclusive))
    assert_true(!run_next_repository_job(pool, root, None))
    lock.close()
    let (code, _) = @process.collect_output_merged("git", [
      "init",
      "--bare",
      "--initial-branch=main",
      repo.git_dir(root),
    ])
    assert_eq(code, 0)
    @fs.write_file(
      "\{repo.git_dir(root)}/moonhub-provisioned",
      job.id.to_string(),
    )
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository_job SET status = 'running' WHERE repository_id = ?",
        params=[job.id],
      )
    })
    assert_true(run_next_repository_job(pool, root, None))
    assert_eq(require_repository_job(pool, team, repo.name).status, "succeeded")
    assert_true(can_access_repository(pool, alice, repo, Write))
  })
}

///|
async test "publication never overwrites an unrelated repository at the destination" {
  with_repository_test_app((_, pool, root, _, _) => {
    let alice = active_user_by_name(pool, "alice")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    let repo = enqueue_repository(
      pool, root, alice, team, "collision", "private", "",
    )
    @fs.mkdir(repo.git_dir(root))
    @fs.write_file("\{repo.git_dir(root)}/keep", "existing data")
    assert_true(run_next_repository_job(pool, root, None))
    assert_eq(require_repository_job(pool, team, repo.name).status, "failed")
    assert_eq(
      @fs.read_file("\{repo.git_dir(root)}/keep").text(),
      "existing data",
    )
    assert_true(!can_access_repository(pool, alice, repo, Read))
    try discard_repository_job(pool, root, alice, team, repo.name) catch {
      BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("discarded a reservation with existing repository data")
    }
  })
}

///|
async test "failed jobs can be discarded and permissions are rechecked before execution" {
  with_repository_test_app((port, pool, root, alice_cookie, _) => {
    let alice = active_user_by_name(pool, "alice")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    let repo = enqueue_repository(
      pool, root, alice, team, "failed", "private", "",
    )
    pool.with_client(client => {
      let _ = client.execute(
        "DELETE FROM team_member WHERE team_id = 1 AND user_id = 1",
      )
    })
    assert_true(run_next_repository_job(pool, root, None))
    assert_eq(require_repository_job(pool, team, repo.name).status, "failed")
    assert_true(!@fs.exists(repo.git_dir(root)))
    pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 1, 'owner')",
      )
    })
    let (confirmation, body) = http_get_path_with_cookie(
      port, "/teams/alice/repositories/failed/discard", alice_cookie,
    )
    assert_eq(confirmation.code, 200)
    let csrf = extract_attr(body, "name=\"csrf_token\"", "value=\"")
    let (discarded, _) = http_post_path_with_cookie(
      port,
      "/teams/alice/repositories/failed/discard",
      "csrf_token=\{csrf}",
      alice_cookie,
    )
    assert_eq(discarded.code, 303)
    ignore(enqueue_repository(pool, root, alice, team, "failed", "private", ""))
    assert_true(run_next_repository_job(pool, root, None))
  })
}

///|
async test "repository schema migration preserves existing ready repositories and SSH identities" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    let base = @fs.read_file("db/base.sql").text()
    let keys = @fs.read_file("db/migrations/001_ssh_keys.sql").text()
    pool.with_client(client => {
      client.batch_execute(base)
      client.batch_execute(keys)
      let _ = client.execute("PRAGMA user_version = 1")
      client.batch_execute(
        (
          #|INSERT INTO "user" (id, name_key, display_name, password_hash) VALUES (1, 'existing', 'Existing', 'hash');
          #|INSERT INTO team (id, name_key, display_name, kind) VALUES (1, 'existing', 'Existing', 'personal');
          #|INSERT INTO team_member VALUES (1, 1, 'owner', datetime('now'));
          #|INSERT INTO repository (team_id, name) VALUES (1, 'repo');
          #|INSERT INTO ssh_key (user_id, title, public_key, fingerprint) VALUES (1, 'Existing key', 'public', 'fingerprint');
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    assert_eq(
      user_ssh_keys(pool, active_user_by_name(pool, "existing")).length(),
      1,
    )
    assert_true(
      can_access_repository(
        pool,
        active_user_by_name(pool, "existing"),
        { owner: "existing", name: "repo", },
        Read,
      ),
    )
  })
}

///|
async test "interrupted clones remove their previous staging directory before recovery" {
  with_repository_test_app((_, pool, root, _, _) => {
    let alice = active_user_by_name(pool, "alice")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    let repo = enqueue_repository(
      pool, root, alice, team, "resume", "private", "",
    )
    let job = require_repository_job(pool, team, repo.name)
    let work = repository_work_directory(root)
    let token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let previous = "\{work}/\{job.id}-\{token}.git"
    @fs.mkdir(previous)
    @fs.write_file("\{previous}/partial", "interrupted clone")
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository_job SET status = 'running', stage_token = ? WHERE repository_id = ?",
        params=[token, job.id],
      )
    })
    assert_true(run_next_repository_job(pool, root, None))
    assert_true(!@fs.exists(previous))
    assert_eq(require_repository_job(pool, team, repo.name).status, "succeeded")
  })
}

///|
async test "SSH imports time out without publishing a repository" {
  with_repository_test_app((_, pool, root, _, _) => {
    let config = mock_import_config(root, "\{root}/alice/demo.git")
    @fs.write_file(
      config.ssh_wrapper,
      "#!/bin/sh\nexec sleep 1\n",
      permission=0o700,
    )
    let config = { ..config, timeout_ms: 25, }
    let alice = active_user_by_name(pool, "alice")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    let repo = enqueue_repository(
      pool, root, alice, team, "timeout", "private", "git@source.example:repo.git",
    )
    assert_true(run_next_repository_job(pool, root, Some(config)))
    let job = require_repository_job(pool, team, repo.name)
    assert_eq(job.status, "failed")
    assert_true(
      job.last_error.unwrap().contains("timed out"),
      msg=job.last_error.unwrap(),
    )
    assert_true(!@fs.exists(repo.git_dir(root)))
    assert_eq(@fs.readdir("\{root}/.imports").length(), 1)
  })
}
