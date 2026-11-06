///|
#derive(Debug)
pub struct RepositoryVariable {
  name : String
  value : String
  version : Int64
  created_at : String
  updated_at : String
}

///|
// Variables are nonsecret repository data and are visible to repository readers.
pub fn list_variables(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> Array[RepositoryVariable] raise {
  let scope = @repository.repository_scope(pool, actor, repo)
  pool.with_client(client => {
    client
    .query_all(
      "SELECT name, value, version, created_at, updated_at FROM repository_variable WHERE repository_id = ? ORDER BY name",
      params=[scope.id],
    )
    .map(row => {
      name: row.get_name("name"),
      value: row.get_name("value"),
      version: row.get_name("version"),
      created_at: row.get_name("created_at"),
      updated_at: row.get_name("updated_at"),
    })
  })
}

///|
// Call within the same transaction that publishes the immutable run snapshot.
fn snapshot_variables(
  tx : @database.DbTransaction,
  repository_id : Int64,
) -> Map[String, String] raise {
  let values : Map[String, String] = Map([])
  for
    row in tx.query_all(
      "SELECT name, value FROM repository_variable WHERE repository_id = ? ORDER BY name",
      params=[repository_id],
    ) {
    values[row.get_name("name")] = row.get_name("value")
  }
  values
}

///|
pub fn save_variable(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  name : String,
  value : String,
  version : Int64,
) -> Unit raise {
  let scope = require_run_author(pool, actor, repo)
  guard @workflow.valid_secret_name(name) &&
    !["__PROTO__", "PROTOTYPE", "CONSTRUCTOR"].contains(name.to_upper()) &&
    version >= 0L else {
    raise @domain.BadRequest(
      message="Use a variable name containing letters, numbers and underscores, without a reserved name, reserved prefix or leading number.",
    )
  }
  guard !value.contains("\u{0000}") && @utf8.encode(value).length() <= 49152 else {
    raise @domain.BadRequest(
      message="Variable values support at most 49,152 UTF-8 bytes and no NUL characters.",
    )
  }
  let name = name.to_upper()
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        let existing = tx.query_opt(
          "SELECT version FROM repository_variable WHERE repository_id = ? AND name = ?",
          params=[scope.id, name],
        )
        match existing {
          Some(existing) => {
            guard (existing.get_name("version") : Int64) == version else {
              raise Conflict(
                "Variable changed. Reload its settings before saving.",
              )
            }
          }
          None => {
            guard version == 0L else {
              raise Conflict(
                "Variable was deleted. Reload its settings before saving.",
              )
            }
          }
        }
        let values = snapshot_variables(tx, scope.id)
        values[name] = value
        guard values.length() <= 500 else {
          raise @domain.BadRequest(
            message="Each repository supports at most 500 variables.",
          )
        }
        guard @utf8.encode(ToJson::to_json(values).stringify()).length() <=
          262144 else {
          raise @domain.BadRequest(
            message="Repository variable values exceed the 256 KiB JSON snapshot limit.",
          )
        }
        // AUTOINCREMENT revisions remain unique after deleting/recreating a name.
        ignore(
          tx.execute(
            "INSERT INTO repository_variable (repository_id, name, value) VALUES (?, ?, ?) ON CONFLICT(repository_id, name) DO UPDATE SET value = excluded.value, version = excluded.version, updated_at = datetime('now')",
            params=[scope.id, name, value],
          ),
        )
        ignore(
          tx.execute(
            "INSERT INTO repository_audit (repository_id, actor_id, kind, detail) VALUES (?, ?, 'variable_saved', ?)",
            params=[scope.id, actor.id, name],
          ),
        )
      },
      immediate=true,
    )
  })
}

///|
pub fn delete_variable(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  name : String,
  version : Int64,
) -> Unit raise {
  let scope = require_run_author(pool, actor, repo)
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        guard tx.execute(
            "DELETE FROM repository_variable WHERE repository_id = ? AND name = ? AND version = ?",
            params=[scope.id, name.to_upper(), version],
          ) ==
          1 else {
          raise Conflict(
            "Variable changed or was deleted. Reload its settings before deleting.",
          )
        }
        ignore(
          tx.execute(
            "INSERT INTO repository_audit (repository_id, actor_id, kind, detail) VALUES (?, ?, 'variable_deleted', ?)",
            params=[scope.id, actor.id, name.to_upper()],
          ),
        )
      },
      immediate=true,
    )
  })
}

///|
pub extend RepositoryVariable with @debug.Debug::{to_repr}
