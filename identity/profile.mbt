///|
pub struct UserProfile {
  name_key : String
  display_name : String
  email : String?
}

///|
pub fn user_profile(
  pool : @database.Database,
  actor : @domain.CurrentUser,
) -> UserProfile raise {
  pool.with_client(client => {
    let row = client.query_opt(
      (
        #|SELECT name_key, display_name, email
        #|FROM "user"
        #|WHERE id = ?
      ),
      params=[actor.id],
    )
    guard row is Some(row) else {
      raise @domain.NotFound(message="account not found")
    }
    {
      name_key: row.get_name("name_key"),
      display_name: row.get_name("display_name"),
      email: row.get_name("email"),
    }
  })
}

///|
pub fn update_display_name(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  display_name : String,
) -> Unit raise {
  pool.with_client(client => {
    client.with_transaction(tx => {
      let changed = tx.execute(
        (
          #|UPDATE "user"
          #|SET display_name = ?, updated_at = datetime('now')
          #|WHERE id = ?
        ),
        params=[display_name, actor.id],
      )
      guard changed == 1 else {
        raise @domain.NotFound(message="account not found")
      }
      // The personal namespace of an account carries its display name.
      let _ = tx.execute(
        (
          #|UPDATE team
          #|SET display_name = ?, updated_at = datetime('now')
          #|WHERE name_key = ? AND kind = 'personal'
        ),
        params=[display_name, actor.name_key],
      )
    })
  })
}
