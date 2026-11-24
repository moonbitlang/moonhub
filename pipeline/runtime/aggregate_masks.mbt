///|
fn capture_call_masks(
  tx : @database.DbTransaction,
  run_id : Int64,
  attempt_id : Int64,
) -> Unit raise {
  let run = tx.query_one(
    "SELECT COALESCE(public_run_id,id) AS public_id,EXISTS (SELECT 1 FROM json_each(definition_json,'$.jobs') j WHERE json_type(j.value,'$.reusable_call')='object') AS has_calls FROM pipeline_run WHERE id=?",
    params=[run_id],
  )
  guard (run.get_name("has_calls") : Bool) else { return }
  let public_id : Int64 = run.get_name("public_id")
  if tx.query_opt(
      "SELECT digest FROM pipeline_call_secret_hash WHERE public_run_id=? AND units=0",
      params=[public_id],
    )
    is Some(_) {
    return
  }
  let mut count : Int64 = tx
    .query_one(
      "SELECT count(*) AS n FROM pipeline_call_secret_hash WHERE public_run_id=?",
      params=[public_id],
    )
    .get_name("n")
  for
    row in tx.query_all(
      "SELECT value FROM pipeline_secret_delivery WHERE attempt_id=?",
      params=[attempt_id],
    ) {
    for mask in secret_masks(row.get_name("value")) {
      if mask.is_empty() {
        continue
      }
      if count >= 4096L {
        ignore(
          tx.execute(
            "INSERT OR IGNORE INTO pipeline_call_secret_hash(public_run_id,digest,units) VALUES(?,'overflow',0)",
            params=[public_id],
          ),
        )
        return
      }
      count += tx
        .execute(
          "INSERT OR IGNORE INTO pipeline_call_secret_hash(public_run_id,digest,units) VALUES(?,?,?)",
          params=[
            public_id,
            @identity.hash_token(mask),
            mask.length().to_int64(),
          ],
        )
        .to_int64()
    }
  }
}

///|
// Bound both stored hashes and hashing work. Overflow suppresses an output;
// it never weakens masking or keeps credentials after attempt cleanup.
fn filter_aggregate_outputs(
  tx : @database.DbTransaction,
  public_id : Int64,
  values : Map[String, String],
) -> Map[String, String] raise {
  let masks : Map[Int32, Set[String]] = Map([])
  for
    row in tx.query_all(
      "SELECT digest,units FROM pipeline_call_secret_hash WHERE public_run_id=?",
      params=[public_id],
    ) {
    let units = (row.get_name("units") : Int64).to_int()
    if units == 0 {
      return Map([])
    }
    let group = masks.get(units).unwrap_or(Set([]))
    group.add(row.get_name("digest"))
    masks[units] = group
  }
  let result : Map[String, String] = Map([])
  let mut work = 0
  for name, value in values {
    let mut safe = true
    for units, digests in masks {
      if units > value.length() {
        continue
      }
      for index in 0..<=(value.length() - units) {
        work += units
        if work > 4194304 ||
          digests.contains(
            @identity.hash_token(value[index:index + units].to_owned()),
          ) {
          safe = false
          break
        }
      }
      if !safe {
        break
      }
    }
    if safe {
      result[name] = value
    }
  }
  result
}
