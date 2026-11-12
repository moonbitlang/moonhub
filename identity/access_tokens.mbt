///|
pub struct AccessToken {
  id : Int64
  name : String
  permission : String
  expires_at : String
  revoked_at : String?
  last_used_at : String?
}

///|
pub fn valid_access_token(token : String) -> Bool {
  token.length() == 67 &&
  token.has_prefix("mh_") &&
  token[3:].iter().all(ch => ch.is_ascii_digit() || (ch >= 'a' && ch <= 'f'))
}

///|
pub fn create_access_token(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  name : String,
  permission : String,
  days : Int32,
) -> String raise {
  guard !name.trim().is_empty() &&
    name.length() <= 100 &&
    name.iter().all(ch => ch.to_int() >= 32 && ch.to_int() != 127) &&
    ["read", "write", "execute", "merge"].contains(permission) &&
    days >= 1 &&
    days <= 365 else {
    raise @domain.BadRequest(message="invalid token name, permission or expiry")
  }
  let token = "mh_" + random_hex(32)
  pool.with_client(client => {
    client.with_transaction(tx => {
      guard tx.query_opt(
          "SELECT id FROM \"user\" WHERE id = ? AND status = 'active'",
          params=[actor.id],
        )
        is Some(_) else {
        raise @domain.Forbidden(message="active account required")
      }
      let count : Int64 = tx
        .query_one(
          "SELECT COUNT(*) AS n FROM access_token WHERE user_id = ? AND revoked_at IS NULL AND expires_at > datetime('now')",
          params=[actor.id],
        )
        .get_name("n")
      guard count < 20L else {
        raise @domain.BadRequest(
          message="revoke an existing token before creating another",
        )
      }
      ignore(
        tx.execute(
          "INSERT INTO access_token(user_id, name, token_hash, permission, expires_at) VALUES (?, ?, ?, ?, datetime('now', '+' || ? || ' days'))",
          params=[
            actor.id,
            name.trim().to_owned(),
            hash_token(token),
            permission,
            days.to_int64(),
          ],
        ),
      )
    })
  })
  token
}

///|
pub fn access_tokens(
  pool : @database.Database,
  actor : @domain.CurrentUser,
) -> Array[AccessToken] raise {
  pool.with_client(client => {
    client
    .query_all(
      "SELECT id, name, permission, expires_at, revoked_at, last_used_at FROM access_token WHERE user_id = ? ORDER BY (revoked_at IS NULL AND expires_at > datetime('now')) DESC, id DESC LIMIT 100",
      params=[actor.id],
    )
    .map(row => {
      id: row.get_name("id"),
      name: row.get_name("name"),
      permission: row.get_name("permission"),
      expires_at: row.get_name("expires_at"),
      revoked_at: row.get_name("revoked_at"),
      last_used_at: row.get_name("last_used_at"),
    })
  })
}

///|
pub fn revoke_access_token(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  id : Int64,
) -> Unit raise {
  pool.with_client(client => {
    guard client.execute(
        "UPDATE access_token SET revoked_at = COALESCE(revoked_at, datetime('now')) WHERE id = ? AND user_id = ?",
        params=[id, actor.id],
      ) ==
      1 else {
      raise @domain.NotFound(message="access token not found")
    }
  })
}

///|
// Tokens grant a subset of current user permissions; they never create a role.
// write = collaboration mutations, execute = write + CI execution, merge =
// write + merge submission. Execution and merging are intentionally independent.
pub fn authenticate_access_token(
  pool : @database.Database,
  token : String,
  required : String,
) -> @domain.CurrentUser raise {
  guard valid_access_token(token) else {
    raise @domain.Unauthorized(message="valid access token required")
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      let row = tx.query_opt(
        "SELECT u.id, u.name_key, u.display_name, u.is_site_admin, a.id AS token_id, a.permission FROM access_token a JOIN \"user\" u ON u.id = a.user_id WHERE a.token_hash = ? AND a.revoked_at IS NULL AND a.expires_at > datetime('now') AND u.status = 'active'",
        params=[hash_token(token)],
      )
      guard row is Some(row) else {
        raise @domain.Unauthorized(
          message="access token expired, revoked or invalid",
        )
      }
      let permission : String = row.get_name("permission")
      guard required == "read" ||
        permission == required ||
        (required == "write" && ["execute", "merge"].contains(permission)) else {
        raise @domain.Forbidden(
          message="access token lacks \{required} permission",
        )
      }
      ignore(
        tx.execute(
          "UPDATE access_token SET last_used_at = datetime('now') WHERE id = ?",
          params=[(row.get_name("token_id") : Int64)],
        ),
      )
      {
        id: row.get_name("id"),
        name_key: row.get_name("name_key"),
        display_name: row.get_name("display_name"),
        is_site_admin: row.get_name("is_site_admin"),
        time_zone: None,
      }
    })
  })
}
