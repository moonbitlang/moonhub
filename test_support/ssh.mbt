///|
pub let test_ssh_public_key : String = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB"

///|
// Bcrypt is synchronous; unrelated fixtures must not consume a Git lock's
// deadline while its holder is waiting for a subprocess. Tests still exercise
// concurrent requests and workers inside each fixture.
pub let database_test_slot : @async.Semaphore = @async.Semaphore(1)

///|
pub async fn with_ssh_test_db(f : async (@database.Database) -> Unit) -> Unit {
  database_test_slot.acquire()
  defer database_test_slot.release()
  @async.with_task_group(group => {
    let pool = @database.new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    @database.initialize_db(pool)
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user" (id, name_key, display_name, password_hash, is_site_admin)
          #|VALUES (1, 'alice', 'Alice', 'test', 0), (2, 'bob', 'Bob', 'test', 0),
          #|  (3, 'admin', 'Admin', 'test', 1);
          #|INSERT INTO team (id, name_key, display_name, kind)
          #|VALUES (1, 'alice', 'Alice', 'personal'), (2, 'bob', 'Bob', 'personal'),
          #|  (3, 'workshop', 'Workshop', 'org'), (4, 'squad', 'Squad', 'org');
          #|INSERT INTO team_member (team_id, user_id, role)
          #|VALUES (1, 1, 'owner'), (2, 2, 'owner'), (3, 1, 'owner'), (4, 2, 'owner');
          #|INSERT INTO repository (team_id, name, visibility)
          #|VALUES (1, 'demo', 'private'), (1, 'public', 'public');
        ),
      )
    })
    f(pool)
  })
}
