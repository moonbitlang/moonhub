///|
pub suberror GitOperationError {
  // Only application-authored messages belong in this public error variant.
  Failure(message~ : String)
  InternalFailure(details~ : String)
}

///|
pub impl Show for GitOperationError with fn output(self, logger) {
  match self {
    Failure(message~) => logger.write_string(message)
    InternalFailure(details~) => logger.write_string(details)
  }
}

///|
fn split_lines(value : String) -> Array[String] {
  value
  .split("\n")
  .filter(line => !line.is_empty())
  .map(line => line.to_owned())
  .collect()
}

///|
pub async fn merge_git_command(
  git_dir : String,
  args : Array[String],
  input~ : String = "",
  limit~ : Int32 = 2097152,
  identity~ : String = "Moonhub",
  strict_utf8~ : Bool = false,
) -> (Int32, String) {
  @async.with_timeout(
    60000,
    () => {
      @async.with_task_group(group => {
        let (reader, output) = @process.read_from_process()
        defer reader.close()
        let (stdin, writer) = @process.write_to_process()
        defer writer.close()
        let process = @process.spawn(
          group,
          "git",
          git_args(
            git_dir,
            [
              "-c", "core.hooksPath=/dev/null", "-c", "core.commitGraph=false", ..args,
            ],
          ),
          inherit_env=false,
          extra_env={
            "PATH": "/usr/bin:/bin",
            "LANG": "C.UTF-8",
            "HOME": "/nonexistent",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": identity,
            "GIT_AUTHOR_EMAIL": "merge@moonhub.invalid",
            "GIT_COMMITTER_NAME": identity,
            "GIT_COMMITTER_EMAIL": "merge@moonhub.invalid",
          },
          stdin~,
          stdout=output,
          stderr=output,
        )
        group.spawn_bg(() => {
          writer.write(input)
          writer.close()
        })
        let bytes : Array[Byte] = []
        while reader.read_some(max_len=8192) is Some(chunk) {
          guard bytes.length() + chunk.length() <= limit else {
            raise Failure(
              message="Git output is too large; narrow the change or inspect it locally",
            )
          }
          for byte in chunk {
            bytes.push(byte)
          }
        }
        let code = process.wait()
        @async.pause()
        let bytes = Bytes::from_array(bytes)
        let text = if strict_utf8 {
          @utf8.decode(bytes) catch {
            _ => raise Failure(message="Git output is not valid UTF-8")
          }
        } else {
          @utf8.decode_lossy(bytes)
        }
        (code, text)
      })
    },
    error=Failure(
      message="Git operation timed out; try again or inspect the branches locally",
    ),
  )
}

///|
pub async fn merge_git(
  git_dir : String,
  args : Array[String],
  input~ : String = "",
) -> String {
  let (code, output) = merge_git_command(git_dir, args, input~)
  guard code == 0 else {
    raise InternalFailure(details="Git operation failed: \{output}")
  }
  output
}

///|
pub fn valid_commit_sha(value : String) -> Bool {
  (value.length() == 40 || value.length() == 64) &&
  value.iter().all(ch => ch.is_ascii_digit() || (ch >= 'a' && ch <= 'f'))
}

///|
pub async fn branch_sha(git_dir : String, branch : String) -> String {
  guard !branch.is_empty() && branch.length() <= 200 else {
    raise Failure(message="invalid branch name")
  }
  let reference = "refs/heads/\{branch}"
  let (valid, _) = merge_git_command(git_dir, ["check-ref-format", reference])
  guard valid == 0 else { raise Failure(message="invalid branch name") }
  let (symbolic, _) = merge_git_command(git_dir, [
    "symbolic-ref", "--quiet", reference,
  ])
  guard symbolic == 1 else {
    raise Failure(message="symbolic branches are not supported")
  }
  let (code, output) = merge_git_command(git_dir, [
    "rev-parse",
    "--verify",
    "\{reference}^{commit}",
  ])
  let sha = output.trim().to_owned()
  guard code == 0 && valid_commit_sha(sha) else {
    raise Failure(message="branch '\{branch}' is missing or has no commits")
  }
  sha
}

///|
pub async fn repository_write_lock(git_dir : String) -> @fs.File {
  let path = "\{git_dir}/moonhub-write.lock"
  if @fs.exists(path) {
    guard @fs.kind(path, follow_symlink=false) is Regular else {
      raise Failure(message="invalid repository write lock")
    }
  }
  let lock = @fs.open(
    path,
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  errdefer lock.close()
  @async.with_timeout(
    15000,
    () => lock.lock(Exclusive),
    error=Failure(
      message="repository is busy; retry after the current push or merge",
    ),
  )
  lock
}

///|
pub(all) struct Revision {
  version : Int64
  source_sha : String
  target_sha : String
  base_sha : String
  merge_tree : String
  block_reason : String
}

///|
pub async fn compare_branches(
  git_dir : String,
  source : String,
  target : String,
) -> Revision {
  guard source != target else {
    raise Failure(message="choose different source and target branches")
  }
  let source_sha = branch_sha(git_dir, source)
  let target_sha = branch_sha(git_dir, target)
  let (code, bases) = merge_git_command(git_dir, [
    "merge-base", "--all", target_sha, source_sha,
  ])
  let lines = split_lines(bases)
  guard code == 0 && lines.length() == 1 && valid_commit_sha(lines[0]) else {
    raise Failure(
      message="branches need exactly one common ancestor for this merge request",
    )
  }
  {
    version: 0L,
    source_sha,
    target_sha,
    base_sha: lines[0],
    merge_tree: "",
    block_reason: "",
  }
}

///|
pub async fn merged_tree(git_dir : String, revision : Revision) -> String {
  guard revision.base_sha != revision.source_sha else {
    raise Failure(
      message="source commits are already included in the target branch",
    )
  }
  let (code, output) = merge_git_command(git_dir, [
    "merge-tree",
    "--write-tree",
    revision.target_sha,
    revision.source_sha,
  ])
  guard code == 0 else {
    if code == 1 {
      raise Failure(
        message="branches have conflicts; resolve them locally and push the source branch",
      )
    }
    raise InternalFailure(details="could not calculate merge: \{output}")
  }
  let tree = output.trim().to_owned()
  guard valid_commit_sha(tree) else {
    raise Failure(message="unexpected Git merge result")
  }
  tree
}

///|
pub struct RevisionComparison {
  base_sha : String
  head_sha : String
  commit : CommitInfo?
  parent_count : Int32
}

///|
pub async fn revision_comparison(
  git_dir : String,
  revision : Revision,
  commit : String?,
) -> RevisionComparison {
  guard commit is Some(commit) else {
    return {
      base_sha: revision.base_sha,
      head_sha: revision.source_sha,
      commit: None,
      parent_count: 0,
    }
  }
  guard valid_commit_sha(commit) else {
    raise @domain.BadRequest(
      message="commit must be a full lowercase commit SHA",
    )
  }
  let (source_code, _) = merge_git_command(git_dir, [
    "merge-base",
    "--is-ancestor",
    commit,
    revision.source_sha,
  ])
  guard source_code == 0 else {
    raise @domain.NotFound(
      message="commit is not part of this merge request version",
    )
  }
  let (target_code, output) = merge_git_command(git_dir, [
    "merge-base",
    "--is-ancestor",
    commit,
    revision.target_sha,
  ])
  if target_code == 0 {
    raise @domain.NotFound(
      message="commit is not part of this merge request version",
    )
  }
  guard target_code == 1 else {
    raise InternalFailure(
      details="could not check commit membership: \{output}",
    )
  }
  let info = merge_git(git_dir, [
    "show", "-s", "--date=short", "--format=%H%x1f%s%x1f%an%x1f%ad", commit, "--",
  ])
  let parents = split_lines(
      merge_git(git_dir, ["rev-list", "--parents", "--no-walk", commit, "--"]),
    )[0]
    .split(" ")
    .map(value => value.to_owned())
    .collect()
  guard parse_commit_line(info.trim().to_owned()) is Some(info) &&
    !parents.is_empty() else {
    raise InternalFailure(details="unexpected merge request commit metadata")
  }
  {
    base_sha: if parents.length() > 1 {
      parents[1]
    } else {
      merge_git(git_dir, ["hash-object", "-t", "tree", "--stdin"])
      .trim()
      .to_owned()
    },
    head_sha: commit,
    commit: Some(info),
    parent_count: parents.length() - 1,
  }
}

///|
pub async fn revision_commits(
  git_dir : String,
  revision : Revision,
  page : Int64,
) -> Array[CommitInfo] {
  guard page > 0L && page <= 100000L else {
    raise @domain.BadRequest(message="invalid commit page")
  }
  let output = merge_git(git_dir, [
    "log",
    "--date=short",
    "--pretty=format:%H%x1f%s%x1f%an%x1f%ad",
    "--max-count=101",
    "--skip=\{((page - 1L) * 100L).to_string()}",
    "\{revision.target_sha}..\{revision.source_sha}",
    "--",
  ])
  split_lines(output).map(line => {
    guard parse_commit_line(line) is Some(commit) else {
      raise InternalFailure(details="unexpected merge request commit metadata")
    }
    commit
  })
}
