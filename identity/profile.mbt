///|
pub struct UserProfile {
  name_key : String
  display_name : String
  email : String?
  time_zone : String?
}

///|
pub fn user_profile(
  pool : @database.Database,
  actor : @domain.CurrentUser,
) -> UserProfile raise {
  pool.with_client(client => {
    let row = client.query_opt(
      (
        #|SELECT name_key, display_name, email,
        #|  (SELECT time_zone FROM user_preferences WHERE user_id = "user".id) AS time_zone
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
      time_zone: row.get_name("time_zone"),
    }
  })
}

///|
pub fn update_profile(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  display_name : String,
  time_zone : String?,
) -> Unit raise {
  guard valid_display_time_zone(time_zone) else {
    raise @domain.BadRequest(message="Choose a valid display time zone.")
  }
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
      let _ = tx.execute(
        "INSERT INTO user_preferences(user_id, time_zone) VALUES (?, NULLIF(?, '')) ON CONFLICT(user_id) DO UPDATE SET time_zone = excluded.time_zone",
        params=[actor.id, time_zone.unwrap_or("")],
      )
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
