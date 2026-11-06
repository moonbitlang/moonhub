///|
pub struct ArtifactBlob {
  id : Int64
  path : String
  size : Int64
  digest : String
}

///|
fn artifact_blob_access(
  tx : @database.DbTransaction,
  id : Int64,
  sig : String,
  operation : String,
  now : Int64,
) -> @database.DbRow raise {
  guard sig.length() == 64 else {
    raise @domain.Unauthorized(message="invalid artifact capability")
  }
  let cap = tx.query_opt(
    "SELECT * FROM pipeline_artifact_capability WHERE token_hash=? AND artifact_id=? AND operation=? AND expires_ms>?",
    params=[@identity.hash_token(sig), id, operation, now],
  )
  guard cap is Some(cap) else {
    raise @domain.Unauthorized(message="artifact capability expired or invalid")
  }
  let access = artifact_access(tx, cap.get_name("runtime_hash"), now)
  let row = tx.query_opt(
    "SELECT * FROM pipeline_artifact WHERE id=? AND repository_id=? AND state <> 'deleted' AND expires_ms>?",
    params=[id, access.repository_id, now],
  )
  guard row is Some(row) &&
    (
      operation == "read" ||
      (row.get_name("attempt_id") : Int64) == access.attempt_id
    ) else {
    raise @domain.Forbidden(message="artifact capability scope mismatch")
  }
  if (row.get_name("kind") : String) == "cache" {
    let cache = tx.query_opt(
      "SELECT scope FROM pipeline_cache WHERE artifact_id=? AND state <> 'deleted'",
      params=[id],
    )
    guard cache is Some(cache) &&
      cache_scopes(tx, access).contains((cache.get_name("scope") : String)) else {
      raise @domain.Forbidden(message="cache scope mismatch")
    }
    if operation == "write" {
      guard (cache.get_name("scope") : String) == cache_scopes(tx, access)[0] else {
        raise @domain.Forbidden(message="cache scope is read-only")
      }
    }
  } else {
    guard (row.get_name("run_id") : Int64) == access.run_id else {
      raise @domain.Forbidden(message="artifact run mismatch")
    }
  }
  row
}

///|
fn artifact_directory(root : String, key : String) -> String {
  root + "/.pipeline-artifacts/" + key
}

///|
async fn make_artifact_directory(root : String, key : String) -> String {
  let parent = root + "/.pipeline-artifacts"
  @fs.mkdir(parent, allow_exist=true, permission=0o700)
  guard @fs.kind(parent, follow_symlink=false) is Directory else {
    raise @domain.BadRequest(message="invalid artifact storage")
  }
  let directory = artifact_directory(root, key)
  @fs.mkdir(directory, allow_exist=true, permission=0o700)
  guard @fs.kind(directory, follow_symlink=false) is Directory else {
    raise @domain.BadRequest(message="invalid artifact storage")
  }
  directory
}

///|
pub fn Coordinator::authorize_artifact_blob(
  self : Coordinator,
  id : Int64,
  sig : String,
  operation : String,
) -> Unit raise {
  self.pool.with_client(client => {
    client.with_transaction(tx => {
      ignore(artifact_blob_access(tx, id, sig, operation, (self.clock)()))
    })
  })
}

///|
pub async fn Coordinator::stage_artifact_block(
  self : Coordinator,
  root : String,
  id : Int64,
  sig : String,
  block : String,
  bytes : Bytes,
) -> Unit {
  guard !block.is_empty() &&
    block.length() <= 128 &&
    block
    .iter()
    .all(ch => {
      ch.is_ascii_alphabetic() ||
      ch.is_ascii_digit() ||
      ['+', '/', '='].contains(ch)
    }) &&
    bytes.length() > 0 &&
    bytes.length() <= 134217728 else {
    raise @domain.BadRequest(message="invalid or oversized artifact block")
  }
  self.make_cache_space(root, id, sig, block, bytes.length().to_int64())
  let key : String = self.pool.with_client(client => {
    client.with_transaction(tx => {
      let row = artifact_blob_access(tx, id, sig, "write", (self.clock)())
      guard bytes.length() <=
        (if (row.get_name("kind") : String) == "cache" {
          134217728
        } else {
          maximum_artifact_block_bytes
        }) else {
        raise @domain.BadRequest(message="block size exceeded")
      }
      guard (row.get_name("state") : String) == "pending" ||
        (row.get_name("kind") : String) == "cache" else {
        raise Conflict("artifact already committed")
      }
      row.get_name("storage_key")
    })
  })
  let replay = self.pool.with_client(client => {
    let row = client.query_opt(
      "SELECT a.kind,a.state,b.digest,b.size FROM pipeline_artifact a JOIN pipeline_artifact_block b ON b.artifact_id=a.id WHERE a.id=? AND b.block_id=?",
      params=[id, block],
    )
    match row {
      Some(row) =>
        (row.get_name("kind") : String) == "cache" &&
        ["uploaded", "ready"].contains((row.get_name("state") : String)) &&
        (row.get_name("size") : Int64) == bytes.length().to_int64() &&
        (row.get_name("digest") : String) ==
        @crypto.bytes_to_hex_string(@crypto.sha256(bytes))
      None => false
    }
  })
  if replay {
    return
  }
  let directory = make_artifact_directory(root, key)
  let file = @identity.random_hex(32)
  let filename = directory + "/" + file
  let mut committed = false
  // A failed or cancelled filesystem write can leave a partial file too.
  defer (if !committed { @fs.remove(filename) catch { _ => () } })
  @fs.write_file(filename, bytes, create_mode=CreateNew, permission=0o600)
  let digest = @crypto.bytes_to_hex_string(@crypto.sha256(bytes))
  let old_file : String? = self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = artifact_blob_access(tx, id, sig, "write", (self.clock)())
        guard (row.get_name("state") : String) == "pending" else {
          raise Conflict("artifact already committed")
        }
        let run : Int64 = row.get_name("run_id")
        let total : Int64 = tx
          .query_one(
            "SELECT COALESCE(SUM(b.size),0) AS size FROM pipeline_artifact_block b JOIN pipeline_artifact a ON a.id=b.artifact_id WHERE a.run_id=? AND a.kind='artifact'",
            params=[run],
          )
          .get_name("size")
        let own : Int64 = tx
          .query_one(
            "SELECT COALESCE(SUM(size),0) AS size FROM pipeline_artifact_block WHERE artifact_id=? AND block_id <> ?",
            params=[id, block],
          )
          .get_name("size")
        let previous = tx.query_opt(
          "SELECT file_key,size FROM pipeline_artifact_block WHERE artifact_id=? AND block_id=?",
          params=[id, block],
        )
        let old_size : Int64 = match previous {
          Some(entry) => entry.get_name("size")
          None => 0L
        }
        if (row.get_name("kind") : String) == "cache" {
          check_cache_bytes(
            tx,
            row.get_name("repository_id"),
            bytes.length().to_int64() - old_size,
          )
        }
        guard own + bytes.length().to_int64() <= maximum_artifact_bytes &&
          (
            (row.get_name("kind") : String) == "cache" ||
            total - old_size + bytes.length().to_int64() <= 4294967296L
          ) else {
          raise @domain.BadRequest(message="artifact byte quota exceeded")
        }
        let count : Int64 = tx
          .query_one(
            "SELECT COUNT(*) AS count FROM pipeline_artifact_block WHERE artifact_id=?",
            params=[id],
          )
          .get_name("count")
        guard count < 64L ||
          tx.query_opt(
            "SELECT block_id FROM pipeline_artifact_block WHERE artifact_id=? AND block_id=?",
            params=[id, block],
          )
          is Some(_) else {
          raise @domain.BadRequest(message="artifact block count exceeded")
        }
        ignore(
          tx.execute(
            "INSERT INTO pipeline_artifact_block(artifact_id,block_id,file_key,size,digest) VALUES(?,?,?,?,?) ON CONFLICT(artifact_id,block_id) DO UPDATE SET file_key=excluded.file_key,size=excluded.size,digest=excluded.digest",
            params=[id, block, file, bytes.length().to_int64(), digest],
          ),
        )
        previous.map(entry => (entry.get_name("file_key") : String))
      },
      immediate=true,
    )
  })
  committed = true
  // Replacing a staged block must not leak files or charge the old bytes twice.
  if old_file is Some(old) {
    @fs.remove(directory + "/" + old) catch {
      _ => ()
    }
  }
}

///|
pub async fn Coordinator::commit_artifact_blocks(
  self : Coordinator,
  root : String,
  id : Int64,
  sig : String,
  blocks : Array[String],
) -> Unit {
  guard !blocks.is_empty() && blocks.length() <= 64 else {
    raise @domain.BadRequest(message="invalid artifact block list")
  }
  let seen : Map[String, Bool] = Map([])
  for block in blocks {
    guard !seen.contains(block) else {
      raise @domain.BadRequest(message="duplicate artifact block")
    }
    seen[block] = true
  }
  let order = ToJson::to_json(blocks).stringify()
  let generation = @identity.random_hex(32)
  let pending : (String, Array[(String, Int64)])? = self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = artifact_blob_access(tx, id, sig, "write", (self.clock)())
        let state : String = row.get_name("state")
        if ["uploaded", "ready"].contains(state) &&
          (row.get_name("block_order") : String) == order {
          return None
        }
        guard state == "pending" else {
          raise Conflict("artifact commit already started")
        }
        let files = blocks.map(block => {
          let entry = tx.query_opt(
            "SELECT file_key,size FROM pipeline_artifact_block WHERE artifact_id=? AND block_id=?",
            params=[id, block],
          )
          guard entry is Some(entry) else {
            raise @domain.BadRequest(message="artifact block missing")
          }
          (
            (entry.get_name("file_key") : String),
            (entry.get_name("size") : Int64),
          )
        })
        ignore(
          tx.execute(
            "UPDATE pipeline_artifact SET state='assembling',generation=?,block_order=? WHERE id=? AND state='pending'",
            params=[generation, order, id],
          ),
        )
        Some(((row.get_name("storage_key") : String), files))
      },
      immediate=true,
    )
  })
  guard pending is Some((key, files)) else { return }
  let directory = artifact_directory(root, key)
  let output_path = directory + "/archive-" + generation
  let mut success = false
  // Register recovery before opening the destination, which itself can fail.
  defer (if !success {
    @fs.remove(output_path) catch {
      _ => ()
    }
    self.pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE pipeline_artifact SET state='pending' WHERE id=? AND state='assembling' AND generation=?",
          params=[id, generation],
        ),
      )
    }) catch {
      _ => ()
    }
  })
  let output = @fs.open(
    output_path,
    mode=ReadWrite,
    create_mode=CreateNew,
    permission=0o600,
  )
  defer output.close()
  let hasher = @crypto.SHA256::new()
  let mut total = 0L
  for (file, size) in files {
    let input = @fs.open(directory + "/" + file, mode=ReadOnly)
    defer input.close()
    guard input.size() == size else {
      raise @domain.BadRequest(message="artifact block changed")
    }
    while input.read_some(max_len=65536) is Some(chunk) {
      total += chunk.length().to_int64()
      guard total <= maximum_artifact_bytes else {
        raise @domain.BadRequest(message="artifact exceeds byte limit")
      }
      hasher.update(chunk)
      output.write(chunk)
    }
  }
  output.sync()
  let digest = "sha256:" + @crypto.bytes_to_hex_string(hasher.finalize())
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        ignore(artifact_blob_access(tx, id, sig, "write", (self.clock)()))
        guard tx.execute(
            "UPDATE pipeline_artifact SET state='uploaded',size=?,digest=? WHERE id=? AND generation=? AND state='assembling'",
            params=[total, digest, id, generation],
          ) ==
          1 else {
          raise Conflict("artifact commit superseded")
        }
      },
      immediate=true,
    )
  })
  success = true
}

///|
pub fn Coordinator::artifact_blob(
  self : Coordinator,
  root : String,
  id : Int64,
  sig : String,
) -> ArtifactBlob raise {
  self.pool.with_client(client => {
    client.with_transaction(tx => {
      let row = artifact_blob_access(tx, id, sig, "read", (self.clock)())
      guard (row.get_name("state") : String) == "ready" else {
        raise @domain.NotFound(message="artifact not finalized")
      }
      {
        id,
        path: artifact_directory(root, row.get_name("storage_key")) +
        "/archive-" +
        (row.get_name("generation") : String),
        size: row.get_name("size"),
        digest: row.get_name("digest"),
      }
    })
  })
}

///|
pub async fn Coordinator::cleanup_artifacts(
  self : Coordinator,
  root : String,
) -> Unit {
  let now = (self.clock)()
  let rows = self.pool.with_client(client => {
    ignore(
      client.execute(
        "UPDATE pipeline_artifact SET state='deleted' WHERE expires_ms<=? OR (state IN ('pending','assembling','uploaded') AND created_ms<? AND EXISTS(SELECT 1 FROM pipeline_job_attempt a WHERE a.id=attempt_id AND a.status='completed'))",
        params=[now, now - 3600000L],
      ),
    )
    ignore(
      client.execute(
        "UPDATE pipeline_cache SET state='deleted' WHERE artifact_id IN (SELECT id FROM pipeline_artifact WHERE state='deleted')",
      ),
    )
    client.query_all(
      "SELECT id,storage_key FROM pipeline_artifact WHERE state='deleted' ORDER BY id LIMIT 100",
    )
  })
  for row in rows {
    let path = artifact_directory(root, row.get_name("storage_key"))
    if @fs.exists(path) {
      @fs.rmdir(path, recursive=true)
    }
    self.pool.with_client(client => {
      ignore(
        client.execute(
          "DELETE FROM pipeline_artifact WHERE id=? AND state='deleted'",
          params=[(row.get_name("id") : Int64)],
        ),
      )
    })
  }
  self.pool.with_client(client => {
    ignore(
      client.execute(
        "DELETE FROM pipeline_artifact_runtime WHERE expires_ms<=?",
        params=[now],
      ),
    )
  })
  let parent = root + "/.pipeline-artifacts"
  if @fs.exists(parent) && @fs.kind(parent, follow_symlink=false) is Directory {
    let directory = @fs.opendir(parent)
    defer directory.close()
    let mut removed = 0
    while directory.next() is Some(entry) {
      let key = entry.name
      if key.length() == 64 &&
        key.iter().all(ch => ch.is_ascii_digit() || ('a' <= ch && ch <= 'f')) {
        let exists = self.pool.with_client(client => {
          client.query_opt(
            "SELECT id FROM pipeline_artifact WHERE storage_key=?",
            params=[key],
          )
          is Some(_)
        })
        if !exists &&
          @fs.kind(parent + "/" + key, follow_symlink=false) is Directory {
          @fs.rmdir(parent + "/" + key, recursive=true)
          removed += 1
          if removed >= 100 {
            break
          }
        }
      }
    }
  }
}

///|
pub fn Coordinator::user_artifact(
  self : Coordinator,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  run_id : Int64,
  id : Int64,
) -> ArtifactBlob raise {
  let scope = @repository.repository_scope(self.pool, actor, repo)
  @repository.authorize_repository(self.pool, actor, repo, Read)
  self.pool.with_client(client => {
    let row = client.query_opt(
      "SELECT * FROM pipeline_artifact WHERE id=? AND run_id=? AND repository_id=? AND kind='artifact' AND state='ready' AND expires_ms>?",
      params=[id, run_id, scope.id, (self.clock)()],
    )
    guard row is Some(row) else {
      raise @domain.NotFound(message="artifact not found")
    }
    {
      id,
      path: artifact_directory(root, row.get_name("storage_key")) +
      "/archive-" +
      (row.get_name("generation") : String),
      size: row.get_name("size"),
      digest: row.get_name("digest"),
    }
  })
}

///|
pub fn Coordinator::artifact_block_limit(
  self : Coordinator,
  id : Int64,
  sig : String,
) -> Int32 raise {
  self.pool.with_client(client => {
    client.with_transaction(tx => {
      let row = artifact_blob_access(tx, id, sig, "write", (self.clock)())
      if (row.get_name("kind") : String) == "cache" {
        134217728
      } else {
        maximum_artifact_block_bytes
      }
    })
  })
}
