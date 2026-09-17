///|
pub struct UserSshKey {
  id : Int64
  title : String
  fingerprint : String
  created_at : String
  last_used_at : String?
  revoked_at : String?
}

///|
pub fn user_ssh_keys(
  pool : @database.Database,
  user : @domain.CurrentUser,
) -> Array[UserSshKey] raise {
  pool.with_client(client => {
    client
    .query_all(
      (
        #|SELECT id, title, fingerprint, created_at, last_used_at, revoked_at
        #|FROM ssh_key WHERE user_id = ?
        #|ORDER BY (revoked_at IS NOT NULL), id DESC
      ),
      params=[user.id],
    )
    .map(row => {
      id: row.get_name("id"),
      title: row.get_name("title"),
      fingerprint: row.get_name("fingerprint"),
      created_at: row.get_name("created_at"),
      last_used_at: row.get_name("last_used_at"),
      revoked_at: row.get_name("revoked_at"),
    })
  })
}

///|
pub fn own_active_ssh_key(
  pool : @database.Database,
  user : @domain.CurrentUser,
  id : Int64,
) -> UserSshKey raise {
  pool.with_client(client => {
    let row = client.query_opt(
      (
        #|SELECT id, title, fingerprint, created_at, last_used_at, revoked_at
        #|FROM ssh_key WHERE id = ? AND user_id = ? AND revoked_at IS NULL
      ),
      params=[id, user.id],
    )
    guard row is Some(row) else {
      raise @domain.NotFound(message="SSH key not found")
    }
    {
      id: row.get_name("id"),
      title: row.get_name("title"),
      fingerprint: row.get_name("fingerprint"),
      created_at: row.get_name("created_at"),
      last_used_at: row.get_name("last_used_at"),
      revoked_at: row.get_name("revoked_at"),
    }
  })
}

///|
pub fn revoke_own_ssh_key(
  pool : @database.Database,
  user : @domain.CurrentUser,
  id : Int64,
) -> Unit raise {
  let changed = pool.with_client(client => {
    client.execute(
      (
        #|UPDATE ssh_key SET revoked_at = datetime('now')
        #|WHERE id = ? AND user_id = ? AND revoked_at IS NULL
      ),
      params=[id, user.id],
    )
  })
  guard changed == 1 else {
    raise @domain.NotFound(message="SSH key not found")
  }
}
