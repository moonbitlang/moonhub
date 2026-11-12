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
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted unsafe source: \{value}")
    }
  }
}

///|
async test "team import identities reject symlinks and disallowed source ports" {
  @test_support.with_git_test_repo((root, source) => {
    let config = @test_support.mock_import_config(root, source)
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
      @domain.BadRequest(_) => ()
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
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("followed an import credential symlink")
    }
  })
}

///|
async test "SSH import failure cleans staging and retry preserves branches tags and default branch" {
  @test_support.with_repository_test_data((pool, root) => {
    let source = "\{root}/alice/demo.git"
    ignore(@gitops.run_git(source, ["branch", "feature/demo", "master"]))
    ignore(@gitops.run_git(source, ["tag", "v1", "master"]))
    let alice = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "alice").unwrap()
    let repo = enqueue_repository(
      pool, root, alice, team, "imported", "private", "git@source.example:group/repo.git",
    )
    assert_true(run_next_repository_job(pool, root, None))
    let failed = require_repository_job(pool, team, repo.name)
    assert_eq(failed.status, "failed")
    assert_true(!@fs.exists(repo.git_dir(root)))
    assert_eq(@fs.readdir("\{root}/.imports").length(), 1)
    let config = @test_support.mock_import_config(root, source)
    retry_repository_job(pool, alice, team, repo.name)
    assert_true(run_next_repository_job(pool, root, Some(config)))
    let completed = require_repository_job(pool, team, repo.name)
    assert_eq(
      completed.status,
      "succeeded",
      msg=completed.last_error.unwrap_or("import failed without a diagnostic"),
    )
    assert_eq(completed.attempt_count, 2L)
    assert_eq(@gitops.default_ref(repo.git_dir(root)), "master")
    let refs = ["for-each-ref", "--format=%(refname):%(objectname)"]
    assert_eq(
      @gitops.run_git(repo.git_dir(root), refs),
      @gitops.run_git(source, refs),
    )
    assert_eq(@gitops.run_git(repo.git_dir(root), ["remote"]), "")
    assert_true(can_access_repository(pool, alice, repo, Read))
  })
}

///|
async test "interrupted repository jobs recover publication and honor the worker lock" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "alice").unwrap()
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
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "alice").unwrap()
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
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("discarded a reservation with existing repository data")
    }
  })
}

///|
async test "interrupted clones remove their previous staging directory before recovery" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "alice").unwrap()
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
  @test_support.with_repository_test_data((pool, root) => {
    let config = @test_support.mock_import_config(
      root,
      "\{root}/alice/demo.git",
    )
    @fs.write_file(
      config.ssh_wrapper,
      "#!/bin/sh\nexec sleep 1\n",
      permission=0o700,
    )
    let config = { ..config, timeout_ms: 25, }
    let alice = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "alice").unwrap()
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
