///|
fn Service::store(self : Service, location : String) -> @storage.Store raise {
  let root = self.root + "/.release-assets"
  match self.storage {
    Some(config) => config.resolve(location, legacy_root=root)
    None => @storage.resolve(location, legacy_root=root)
  }
}

///|
fn Service::destination(self : Service) -> String {
  match self.storage {
    Some(config) => config.releases
    None => "legacy-fs"
  }
}

///|
fn asset_name(name : String) -> Unit raise {
  guard !name.is_empty() &&
    @utf8.encode(name).length() <= 240 &&
    name != "." &&
    name != ".." &&
    !name.contains("/") &&
    !name.contains("\\") &&
    name.iter().all(c => c.to_int() >= 32 && c.to_int() != 127) else {
    raise @domain.BadRequest(message="invalid release asset name")
  }
}

///|
pub async fn Service::upload(
  self : Service,
  access : Access,
  release_id : Int64,
  name : String,
  label : String,
  media_type : String,
  next : async () -> Bytes?,
) -> Asset {
  asset_name(name)
  validate_text(label, 1024)
  guard !media_type.is_empty() &&
    media_type.length() <= 120 &&
    media_type.iter().all(c => c.to_int() >= 32 && c.to_int() < 127) else {
    raise @domain.BadRequest(message="invalid asset content type")
  }
  ignore(self.authorize(access, true))
  let release = self.get(access, release_id)
  guard release.draft else {
    raise Conflict("published release assets are immutable")
  }
  let key = "release_" + @identity.random_hex(32)
  let location = self.destination()
  let store = self.store(location)
  let id = self.pool.with_client(c => {
    c.with_transaction(
      tx => {
        guard tx.query_opt(
            "SELECT id FROM repository_release WHERE id=? AND draft=1 AND deleted=0 AND revision=?",
            params=[release_id, release.revision],
          )
          is Some(_) else {
          raise Conflict("release changed")
        }
        guard tx.query_opt(
            "SELECT id FROM release_asset WHERE release_id=? AND name=? AND state<>'deleted'",
            params=[release_id, name],
          )
          is None else {
          raise Conflict("asset name already exists")
        }
        guard (
            tx
            .query_one(
              "SELECT count(*) n FROM release_asset WHERE release_id=? AND state<>'deleted'",
              params=[release_id],
            )
            .get_name("n") : Int64) <
          100L else {
          raise @domain.BadRequest(message="release asset limit exceeded")
        }
        ignore(
          tx.execute(
            "INSERT INTO release_asset(release_id,name,label,media_type,state,commit_sha,storage_key,location,expires_ms) VALUES(?,?,?,?,'pending',?,?,?,?)",
            params=[
              release_id,
              name,
              label,
              media_type,
              release.commit_sha,
              key,
              location,
              (self.clock)() + 1200000L,
            ],
          ),
        )
        (tx.query_one("SELECT last_insert_rowid() id").get_name("id") : Int64)
      },
      immediate=true,
    )
  })
  let parts : Array[@storage.Part] = []
  let hash = @crypto.SHA256::new()
  let mut total = 0L
  let buffer : Array[Byte] = []
  let flush : async () -> Unit = () => {
    guard !buffer.is_empty() && parts.length() < 256 else {
      raise @domain.BadRequest(message="release asset exceeds 2 GiB")
    }
    let bytes = Bytes::from_array(buffer)
    let part = key + "/part-" + parts.length().to_string()
    store.put(part, bytes)
    parts.push({
      key: part,
      size: bytes.length().to_int64(),
      digest: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    })
    buffer.clear()
  }
  errdefer (self.pool.with_client(c => {
    ignore(
      c.execute(
        "UPDATE release_asset SET state='deleted',expires_ms=? WHERE id=? AND state='pending'",
        params=[(self.clock)() + 600000L, id],
      ),
    )
  }) catch {
    _ => ()
  })
  @async.with_timeout(600000, () => {
    while next() is Some(bytes) {
      ignore(self.authorize(access, true))
      total += bytes.length().to_int64()
      guard total <= 2147483648L else {
        raise @domain.BadRequest(message="release asset exceeds 2 GiB")
      }
      hash.update(bytes)
      for b in bytes {
        buffer.push(b)
        if buffer.length() == 8388608 {
          flush()
        }
      }
    }
    if !buffer.is_empty() {
      flush()
    }
    guard total > 0L else {
      raise @domain.BadRequest(message="release assets must not be empty")
    }
    let object = store.compose(key + "/archive", parts)
    let digest = "sha256:" + @crypto.bytes_to_hex_string(hash.finalize())
    guard object.size == total && object.digest == digest else {
      raise Conflict("release asset integrity mismatch")
    }
    ignore(self.authorize(access, true))
    self.pool.with_client(c => {
      c.with_transaction(
        tx => {
          guard tx.query_opt(
              "SELECT id FROM repository_release WHERE id=? AND draft=1 AND deleted=0 AND revision=?",
              params=[release_id, release.revision],
            )
            is Some(_) else {
            raise Conflict("release changed during upload")
          }
          guard tx.execute(
              "UPDATE release_asset SET state='ready',size=?,digest=? WHERE id=? AND state='pending' AND expires_ms>?",
              params=[total, digest, id, (self.clock)()],
            ) ==
            1 else {
            raise Conflict("asset upload expired")
          }
          for part in parts {
            ignore(
              tx.execute(
                "INSERT OR IGNORE INTO release_blob_garbage(location,storage_key,kind,due_ms) VALUES(?,?,'object',?)",
                params=[location, part.key, (self.clock)()],
              ),
            )
          }
        },
        immediate=true,
      )
    })
  })
  self.get_asset(access, id)
}

///|
pub fn Service::get_asset(
  self : Service,
  access : Access,
  id : Int64,
) -> Asset raise {
  let repo = self.authorize(access, false)
  let drafts = self.writer(access)
  self.pool.with_client(c => {
    let row = c.query_opt(
      "SELECT a.* FROM release_asset a JOIN repository_release r ON r.id=a.release_id WHERE a.id=? AND a.state='ready' AND r.repository_id=? AND r.deleted=0 AND (r.draft=0 OR ?=1)",
      params=[id, repo, drafts],
    )
    guard row is Some(row) else {
      raise @domain.NotFound(message="release asset not found")
    }
    asset(row)
  })
}

///|
pub fn Service::delete_asset(
  self : Service,
  access : Access,
  id : Int64,
) -> Unit raise {
  ignore(self.authorize(access, true))
  let a = self.get_asset(access, id)
  self.pool.with_client(c => {
    c.with_transaction(
      tx => {
        guard tx.query_opt(
            "SELECT id FROM repository_release WHERE id=? AND draft=1 AND deleted=0",
            params=[a.release_id],
          )
          is Some(_) else {
          raise Conflict("published release assets are immutable")
        }
        ignore(
          tx.execute(
            "UPDATE release_asset SET state='deleted',expires_ms=? WHERE id=? AND state='ready'",
            params=[(self.clock)() + 600000L, id],
          ),
        )
      },
      immediate=true,
    )
  })
}

///|
pub async fn Service::download(
  self : Service,
  access : Access,
  id : Int64,
  consume : async (Asset, @storage.Reader, () -> Unit raise) -> Unit,
) -> Unit {
  let asset = self.get_asset(access, id)
  let authorize : () -> Unit raise = () => ignore(self.get_asset(access, id))
  self
  .store(asset.location)
  .with_reader(asset.storage_key + "/archive", asset.size, reader => {
    authorize()
    consume(asset, reader, authorize)
  })
}

///|
pub async fn Service::cleanup(self : Service) -> Unit {
  let now = (self.clock)()
  self.pool.with_client(c => {
    ignore(
      c.execute(
        "DELETE FROM release_asset WHERE (state='deleted' OR state='pending') AND expires_ms<=?",
        params=[now],
      ),
    )
  })
  let rows = self.pool.with_client(c => {
    c.query_all(
      "SELECT * FROM release_blob_garbage WHERE due_ms<=? ORDER BY due_ms,id LIMIT 100",
      params=[now],
    )
  })
  for row in rows {
    let id : Int64 = row.get_name("id")
    try {
      if (row.get_name("kind") : String) == "object" {
        self.store(row.get_name("location")).remove(row.get_name("storage_key"))
      } else {
        self
        .store(row.get_name("location"))
        .remove_namespace(row.get_name("storage_key"))
      }
      self.pool.with_client(c => {
        ignore(
          c.execute("DELETE FROM release_blob_garbage WHERE id=?", params=[id]),
        )
      })
    } catch {
      _ =>
        self.pool.with_client(c => {
          ignore(
            c.execute("UPDATE release_blob_garbage SET due_ms=? WHERE id=?", params=[
              now + 60000L,
              id,
            ]),
          )
        })
    }
  }
}
