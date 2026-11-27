///|
// Trusted receive hooks use a private server-side context file. The job token
// never enters Git arguments, hook arguments, repository config or Git output.
pub async fn job_git_hook(
  pool : @database.Database,
  context_file : String,
  phase : String,
) -> Unit {
  let bytes = @fs.read_file(context_file)
  guard bytes.binary().length() <= 4096 &&
    @json.parse(bytes.text())
    is {
      "token": String(token),
      "repository": String(repository),
      "push_id": String(push_id),
      ..
    } else {
    raise @domain.BadRequest(message="invalid job Git context")
  }
  let data : Array[Byte] = []
  while @stdio.stdin.read_some(max_len=8192) is Some(chunk) {
    guard data.length() + chunk.length() <= 1048576 else {
      raise @domain.BadRequest(message="too many ref updates")
    }
    data.push_iter(chunk.iter())
  }
  let updates = @utf8.decode(Bytes::from_array(data))
  let repo = @domain.parse_repo_name(repository)
  let actor = @runtime.Coordinator::new(pool).authenticate_job_api(
    token, repo, "git:write",
  )
  let scope = @repository.repository_scope(pool, actor, repo)
  @repository.authorize_repository(pool, actor, repo, @repository.Write)
  if ["check", "preparing", "prepared"].contains(phase) {
    @collaboration.check_received_ref_rules(pool, scope, updates)
  }
  if phase != "check" {
    @repository.record_received_transaction(
      pool,
      actor,
      repo,
      push_id,
      phase,
      updates,
      workflow_events=false,
    )
  }
}

///|
pub async fn job_git_exchange(
  pool : @database.Database,
  coordinator : @runtime.Coordinator,
  root : String,
  binary : String,
  repo : @domain.RepoId,
  token : String,
  body : Bytes,
  advertise : Bool,
) -> Bytes {
  guard body.length() <= 67108864 else {
    raise @domain.BadRequest(message="Git push exceeds 64 MiB")
  }
  let actor = coordinator.authenticate_job_api(token, repo, "git:write")
  let scope = @repository.repository_scope(pool, actor, repo)
  @repository.with_repository_write(pool, root, actor, scope, (scope, dir) => {
    let temporary = @fs.tmpdir(prefix="moonhub-job-git-")
    defer @async.protect_from_cancel(() => @fs.rmdir(temporary, recursive=true))
    let context_file = temporary + "/context.json"
    @fs.write_file(
      context_file,
      (
        {
          "token": token,
          "repository": repo.path(),
          "push_id": @identity.random_hex(16),
        } : Json).stringify(),
      permission=0o600,
    )
    @fs.write_file(
      temporary + "/pre-receive",
      "#!/bin/sh\nexec \"$MOONHUB_BIN\" job-git-hook \"$MOONHUB_JOB_CONTEXT\" check\n",
      permission=0o700,
    )
    @fs.write_file(
      temporary + "/reference-transaction",
      "#!/bin/sh\nexec \"$MOONHUB_BIN\" job-git-hook \"$MOONHUB_JOB_CONTEXT\" \"$1\"\n",
      permission=0o700,
    )
    let db_path : String = pool.with_client(c => {
      c
      .query_all("PRAGMA database_list")
      .iter()
      .find_first(row => (row.get_name("name") : String) == "main")
      .unwrap()
      .get_name("file")
    })
    guard !db_path.is_empty() else {
      raise @domain.BadRequest(message="job Git requires a persistent database")
    }
    let output = @async.with_timeout(60000, () => {
      @async.with_task_group(group => {
        let (input, writer) = @process.write_to_process()
        defer writer.close()
        group.spawn_bg(() => {
          writer.write(body)
          writer.close()
        })
        let (reader, output) = @process.read_from_process()
        defer reader.close()
        ignore(coordinator.authenticate_job_api(token, repo, "git:write"))
        @repository.require_current_scope(pool, scope)
        let child = @process.spawn(
          group,
          "git",
          [
            "-c",
            "transfer.hideRefs=refs/moonhub/",
            "-c",
            "receive.fsckObjects=true",
            "-c",
            "receive.maxInputSize=67108864",
            "-c",
            "receive.advertiseAtomic=true",
            "-c",
            "core.hooksPath=" + temporary,
            "receive-pack",
            "--stateless-rpc",
            ..if advertise {
              ["--advertise-refs"]
            } else {
              []
            },
            dir,
          ],
          inherit_env=false,
          extra_env={
            "PATH": "/usr/bin:/bin",
            "HOME": "/nonexistent",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "DB_PATH": db_path,
            "MOONHUB_BIN": binary,
            "MOONHUB_JOB_CONTEXT": context_file,
          },
          stdin=input,
          stdout=output,
          stderr=@process.redirect_to_file("/dev/null"),
        )
        group.spawn_bg(no_wait=true, () => {
          for ;; {
            ignore(coordinator.authenticate_job_api(token, repo, "git:write"))
            @async.sleep(250)
          }
        })
        let bytes : Array[Byte] = []
        if advertise {
          bytes.push_iter(b"001f# service=git-receive-pack\n0000".iter())
        }
        while reader.read_some(max_len=8192) is Some(chunk) {
          guard bytes.length() + chunk.length() <= 4194304 else {
            raise @domain.BadRequest(message="Git response exceeds limits")
          }
          bytes.push_iter(chunk.iter())
        }
        guard child.wait() == 0 else {
          raise @domain.BadRequest(message="Git push was rejected")
        }
        Bytes::from_array(bytes)
      })
    })
    @repository.recover_ref_events_locked(pool, scope, dir)
    output
  })
}
