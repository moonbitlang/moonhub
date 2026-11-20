///|
fn Coordinator::source_snapshot(
  self : Coordinator,
  id : Int64,
  token : String,
) -> (@domain.RepoId, String) raise {
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = load_live_attempt(tx, id, token, (self.clock)())
        guard (row.get_name("status") : String) == "running" &&
          (row.get_name("cancel_at_ms") : Int64?) is None else {
          raise Conflict("source requires a running, authorized attempt")
        }
        guard attempt_job(row).contents_read else {
          raise @domain.Forbidden(
            message="job permissions deny contents access",
          )
        }
        let repo : @domain.RepoId = {
          owner: row.get_name("owner_name"),
          name: row.get_name("repo_name"),
        }
        (repo, (row.get_name("commit_sha") : String))
      },
      immediate=true,
    )
  })
}

///|
fn validate_source_tree(
  tree : String,
  git_bundle~ : Bool = false,
) -> Unit raise {
  let mut count = 0
  for entry in tree.split("\u{0000}") {
    if entry.is_empty() {
      continue
    }
    count += 1
    guard count <= 10000 && entry.split_once("\t") is Some((meta, path)) else {
      raise @domain.BadRequest(message="source tree exceeds checkout limits")
    }
    // Tar extraction accepts regular files only. Git bundles preserve symlink
    // blobs and gitlinks without following links or fetching submodules on the
    // server. Git performs checkout inside the isolated job workspace.
    guard (
        meta.has_prefix("100644 blob ") ||
        meta.has_prefix("100755 blob ") ||
        (
          git_bundle &&
          (meta.has_prefix("120000 blob ") || meta.has_prefix("160000 commit "))
        )
      ) &&
      path.length() <= 1024 &&
      !path.has_prefix("/") &&
      !path.contains("\\") &&
      path.iter().all(ch => ch.to_int() >= 32 && ch.to_int() != 127) &&
      path
      .split("/")
      .all(part => {
        !["", ".", "..", ".git", ".home", ".tmp"].contains(part.to_owned())
      }) else {
      raise @domain.BadRequest(
        message="source contains unsupported file modes or reserved paths",
      )
    }
  }
}

///|
pub async fn Coordinator::read_source(
  self : Coordinator,
  root : String,
  id : Int64,
  token : String,
) -> Bytes {
  let (repo, sha) = self.source_snapshot(id, token)
  let bytes = @async.with_timeout(30000, () => {
    let git_dir = @repository.resolve_repository_dir(root, repo)
    let (code, tree) = @gitops.merge_git_command(
      git_dir,
      ["ls-tree", "-rz", "--full-tree", sha],
      limit=2097152,
      strict_utf8=true,
    )
    guard code == 0 else {
      raise @domain.BadRequest(message="source checkout failed")
    }
    validate_source_tree(tree)
    @async.with_task_group(group => {
      let (reader, output) = @process.read_from_process()
      defer reader.close()
      let process = @process.spawn(
        group,
        "git",
        [
          "-c", "core.hooksPath=/dev/null", "--git-dir", git_dir, "archive", "--format=tar",
          sha,
        ],
        inherit_env=false,
        extra_env={
          "PATH": "/usr/bin:/bin",
          "HOME": "/nonexistent",
          "GIT_CONFIG_NOSYSTEM": "1",
          "GIT_CONFIG_GLOBAL": "/dev/null",
        },
        stdin=@process.redirect_from_file("/dev/null"),
        stdout=output,
        stderr=@process.redirect_to_file("/dev/null"),
      )
      let bytes : Array[Byte] = []
      while reader.read_some(max_len=8192) is Some(chunk) {
        guard bytes.length().to_int64() + chunk.length().to_int64() <=
          @protocol.max_source_bytes else {
          raise @domain.BadRequest(message="source archive is too large")
        }
        bytes.push_iter(chunk.iter())
      }
      guard process.wait() == 0 else {
        raise @domain.BadRequest(message="source checkout failed")
      }
      Bytes::from_array(bytes)
    })
  })
  // Git I/O yields; reject access revoked or expired during archive generation.
  ignore(self.source_snapshot(id, token))
  bytes
}

///|
// Export only the pinned run commit through a disposable shallow repository.
pub async fn Coordinator::read_source_bundle(
  self : Coordinator,
  root : String,
  id : Int64,
  token : String,
) -> Bytes {
  let (repo, sha) = self.source_snapshot(id, token)
  let bytes = @async.with_timeout(30000, () => {
    let git_dir = @repository.resolve_repository_dir(root, repo)
    let (code, tree) = @gitops.merge_git_command(
      git_dir,
      ["ls-tree", "-rz", "--full-tree", sha],
      limit=2097152,
      strict_utf8=true,
    )
    guard code == 0 else {
      raise @domain.BadRequest(message="source checkout failed")
    }
    validate_source_tree(tree, git_bundle=true)
    let temporary = @fs.tmpdir(prefix="moonhub-source-bundle-")
    defer @fs.rmdir(temporary, recursive=true)
    let repository = temporary + "/source.git"
    let env : Map[String, String] = {
      "PATH": "/usr/bin:/bin",
      "HOME": "/nonexistent",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_TERMINAL_PROMPT": "0",
    }
    for
      args in [
        ["init", "--bare", "--quiet", repository],
        [
          "--git-dir", repository, "fetch", "--quiet", "--no-tags", "--depth=1",
          "--", git_dir, sha,
        ],
        [
          "--git-dir", repository, "update-ref", "refs/heads/moonhub-source", sha,
        ],
      ] {
      let code = @process.run(
        "git",
        ["-c", "core.hooksPath=/dev/null", ..args],
        inherit_env=false,
        extra_env=env,
        stdin=@process.redirect_from_file("/dev/null"),
        stdout=@process.redirect_to_file("/dev/null"),
        stderr=@process.redirect_to_file("/dev/null"),
      )
      guard code == 0 else {
        raise @domain.BadRequest(message="source bundle preparation failed")
      }
    }
    @async.with_task_group(group => {
      let (reader, output) = @process.read_from_process()
      defer reader.close()
      let process = @process.spawn(
        group,
        "git",
        [
          "-c", "core.hooksPath=/dev/null", "--git-dir", repository, "bundle", "create",
          "-", "refs/heads/moonhub-source",
        ],
        inherit_env=false,
        extra_env=env,
        stdin=@process.redirect_from_file("/dev/null"),
        stdout=output,
        stderr=@process.redirect_to_file("/dev/null"),
      )
      let data : Array[Byte] = []
      while reader.read_some(max_len=8192) is Some(chunk) {
        guard data.length().to_int64() + chunk.length().to_int64() <=
          @protocol.max_source_bytes else {
          raise @domain.BadRequest(message="source bundle exceeds 64 MiB")
        }
        data.push_iter(chunk.iter())
      }
      guard process.wait() == 0 else {
        raise @domain.BadRequest(message="source bundle creation failed")
      }
      Bytes::from_array(data)
    })
  })
  ignore(self.source_snapshot(id, token))
  bytes
}
