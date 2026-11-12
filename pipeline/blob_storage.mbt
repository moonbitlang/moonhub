///|
fn Coordinator::capture_storage_location(
  self : Coordinator,
  tx : @database.DbTransaction,
  id : Int64,
  cache : Bool,
) -> Unit raise {
  if self.storage is Some(config) {
    ignore(
      tx.execute(
        "INSERT INTO pipeline_artifact_location(artifact_id,location) VALUES(?,?)",
        params=[id, if cache { config.caches } else { config.artifacts }],
      ),
    )
  }
}

///|
fn blob_location(tx : @database.DbTransaction, id : Int64) -> String raise {
  tx
  .query_opt(
    "SELECT location FROM pipeline_artifact_location WHERE artifact_id=?",
    params=[id],
  )
  .map(row => (row.get_name("location") : String))
  .unwrap_or("legacy-fs")
}

///|
fn Coordinator::blob_store(
  self : Coordinator,
  root : String,
  location : String,
) -> @storage.Store raise {
  match self.storage {
    Some(config) =>
      config.resolve(location, legacy_root=root + "/.pipeline-artifacts")
    None =>
      @storage.resolve(location, legacy_root=root + "/.pipeline-artifacts")
  }
}

///|
fn reserve_blob(
  tx : @database.DbTransaction,
  location : String,
  key : String,
  now : Int64,
) -> Unit raise {
  // Register before remote I/O. Linking the object and removing its recovery
  // intent happen in one transaction. A killed upload cannot create an orphan.
  ignore(
    tx.execute(
      "INSERT OR REPLACE INTO pipeline_blob_garbage(location,key,kind,not_before_ms) VALUES(?,?,'object',?)",
      params=[location, key, now + 3600000L],
    ),
  )
}

///|
fn release_blob(
  tx : @database.DbTransaction,
  location : String,
  key : String,
) -> Unit raise {
  ignore(
    tx.execute(
      "DELETE FROM pipeline_blob_garbage WHERE location=? AND key=? AND kind='object'",
      params=[location, key],
    ),
  )
}

///|
pub async fn ArtifactBlob::with_reader(
  self : ArtifactBlob,
  consume : async (@storage.Reader) -> Unit,
) -> Unit {
  @async.with_timeout(30000, () => self.downloads.acquire())
  defer self.downloads.release()
  self.store.with_reader(self.key, self.size, consume)
}

///|
async fn Coordinator::cleanup_blob_garbage(
  self : Coordinator,
  root : String,
) -> Bool {
  let mut complete = true
  let now = (self.clock)()
  let rows = self.pool.with_client(client => {
    client.query_all(
      "SELECT location,key,kind FROM pipeline_blob_garbage WHERE not_before_ms<=? ORDER BY not_before_ms LIMIT 100",
      params=[now],
    )
  })
  for row in rows {
    let location : String = row.get_name("location")
    let key : String = row.get_name("key")
    let kind : String = row.get_name("kind")
    try {
      let store = self.blob_store(root, location)
      // Leave the intent intact on failure. The next sweep retries remote deletion.
      if kind == "namespace" {
        store.remove_namespace(key)
      } else {
        store.remove(key)
      }
      self.pool.with_client(client => {
        ignore(
          client.execute(
            "DELETE FROM pipeline_blob_garbage WHERE location=? AND key=? AND kind=?",
            params=[location, key, kind],
          ),
        )
      })
    } catch {
      _ => complete = false
    }
  }
  complete
}
