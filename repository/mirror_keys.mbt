///|
priv struct MirrorKeyPair {
  private_key : String
  public_key : String
}

///|
async fn generate_mirror_key(root : String) -> MirrorKeyPair {
  let work = mirror_work_root(root)
  let directory = work + "/key-" + @identity.random_hex(16)
  @fs.mkdir(directory, permission=0o700)
  defer @fs.rmdir(directory, recursive=true)
  let identity = directory + "/id_ed25519"
  @async.with_timeout(10000, () => {
    @async.with_task_group(group => {
      let process = @process.spawn(
        group,
        "/usr/bin/ssh-keygen",
        [
          "-q", "-t", "ed25519", "-N", "", "-C", "moonhub-mirror", "-f", identity,
        ],
        inherit_env=false,
        extra_env={ "PATH": "/usr/bin:/bin", "HOME": directory },
        stdin=@process.redirect_from_file("/dev/null"),
        stdout=@process.redirect_to_file("/dev/null"),
        stderr=@process.redirect_to_file("/dev/null"),
      )
      guard process.wait() == 0 else {
        raise @domain.BadRequest(
          message="Could not generate mirror SSH key; try again or contact an administrator",
        )
      }
    })
  })
  {
    private_key: @fs.read_file(identity).text(),
    public_key: @fs.read_file(identity + ".pub").text().trim().to_owned(),
  }
}

///|
pub async fn rotate_mirror_key(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  id : Int64,
  version : Int64,
) -> Unit {
  let scope = require_mirror_manager(pool, actor, repo)
  let lock = mirror_lock(root, id)
  defer lock.close()
  ignore(require_mirror_manager(pool, actor, repo))
  guard pool.with_client(client => {
    client.query_opt(
      "SELECT id FROM repository_mirror WHERE id=? AND repository_id=? AND version=?",
      params=[id, scope.id, version],
    )
    is Some(_)
  }) else {
    raise @domain.BadRequest(
      message="mirror changed or was removed; reload before rotating its key",
    )
  }
  let key = generate_mirror_key(root)
  ignore(require_mirror_manager(pool, mirror_actor(pool, actor.id), repo))
  pool.with_client(client => {
    client.with_transaction(tx => {
      guard tx.query_opt(
          "UPDATE repository_mirror SET creator_id=?,active=0,status='disabled',version=version+1,generation=generation+1,attempts=0,last_error='',lease=NULL,locked_at=NULL WHERE id=? AND repository_id=? AND version=? RETURNING id",
          params=[actor.id, id, scope.id, version],
        )
        is Some(_) else {
        raise @domain.BadRequest(
          message="mirror changed or was removed; reload before rotating its key",
        )
      }
      ignore(
        tx.execute(
          "INSERT INTO mirror_ssh_key(mirror_id,private_key,public_key) VALUES(?,?,?) ON CONFLICT(mirror_id) DO UPDATE SET private_key=excluded.private_key,public_key=excluded.public_key",
          params=[id, key.private_key, key.public_key],
        ),
      )
      ignore(
        tx.execute(
          "INSERT INTO repository_audit(repository_id,actor_id,kind,detail) VALUES(?,?,'push_mirror_key_rotated',?)",
          params=[scope.id, actor.id, id.to_string()],
        ),
      )
    })
  })
}
