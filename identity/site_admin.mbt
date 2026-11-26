///|
/// Grants site administrator access to an active account and returns its username.
pub fn grant_site_admin(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  user_id : Int64,
) -> String raise {
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        guard tx.query_opt(
            (
              #|SELECT 1 FROM "user"
              #|WHERE id = ? AND status = 'active' AND is_site_admin = 1
            ),
            params=[actor.id],
          )
          is Some(_) else {
          raise @domain.Forbidden(message="site administrator required")
        }
        guard tx.query_opt(
            "SELECT name_key FROM \"user\" WHERE id = ? AND status = 'active'",
            params=[user_id],
          )
          is Some(target) else {
          raise @domain.NotFound(message="active user not found")
        }
        let _ = tx.execute(
          (
            #|UPDATE "user"
            #|SET is_site_admin = 1, updated_at = datetime('now')
            #|WHERE id = ? AND is_site_admin = 0
          ),
          params=[user_id],
        )
        target.get_name("name_key")
      },
      immediate=true,
    )
  })
}
