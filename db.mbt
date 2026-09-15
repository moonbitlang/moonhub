///|
extenum @moonback.TypedBox += {
  DbPool(Database)
}

///|
let config_db_pool : @moonback.TypedKey[Database] = TypedKey(
  name="moonhub.db_pool",
  box=pool => DbPool(pool),
  unbox=err => {
    match err {
      DbPool(pool) => Some(pool)
      _ => None
    }
  },
)

///|
fn db_pool(ctx : @moonback.ModuleContext) -> Database {
  match ctx.config().get_custom(config_db_pool) {
    Some(pool) => pool
    None => abort("missing moonhub db pool")
  }
}

///|
fn[T] new_db_pool(
  config : DbConfig,
  group : @async.TaskGroup[T],
) -> Database raise @moondb.DbError {
  ignore(group)
  let driver = @sqlite.SqliteDriver::open(config.path)
  errdefer driver.close()
  let _ = driver.execute("PRAGMA foreign_keys = ON", [])
  let _ = driver.execute("PRAGMA busy_timeout = 5000", [])
  { driver, }
}

///|
let database_schema_version : Int64 = 4L

///|
async fn initialize_db(pool : Database) -> Unit {
  pool.with_client(client => {
    let _ = client.execute("PRAGMA foreign_keys = ON", params=[])
    let _ = client.execute("PRAGMA journal_mode = WAL", params=[])
    let _ = client.execute("PRAGMA busy_timeout = 5000", params=[])
  })
  let table_row = pool.with_client(client => {
    client.query_opt(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'user'",
    )
  })
  if table_row is None {
    let sql = @fs.read_file("db/base.sql").text()
    pool.with_client(client => client.batch_execute(sql))
  }
  let ssh_migration = @fs.read_file("db/migrations/001_ssh_keys.sql").text()
  let repository_migration = @fs.read_file(
    "db/migrations/002_repository_jobs.sql",
  ).text()
  let address_migration = @fs.read_file("db/migrations/003_ssh_addresses.sql").text()
  let merge_migration = @fs.read_file("db/migrations/004_merge_requests.sql").text()
  pool.with_client(client => {
    client.with_transaction(tx => {
      let row = tx.query_one("PRAGMA user_version")
      let version : Int64 = row.get_name("user_version")
      guard version <= database_schema_version else {
        raise BadRequest(
          message="database schema is newer than this moonhub version",
        )
      }
      if version == 0L {
        tx.driver.exec_script(ssh_migration)
      }
      if version < 2L {
        tx.driver.exec_script(repository_migration)
      }
      if version < 3L {
        tx.driver.exec_script(address_migration)
      }
      if version < 4L {
        tx.driver.exec_script(merge_migration)
      }
      let _ = tx.execute("PRAGMA user_version = 4")
    })
  })
}

///|
fn ensure_root_invitation(pool : Database, root : RootUserConfig) -> Unit raise {
  pool.with_client(client => {
    let admin_sql =
      #|SELECT id
      #|FROM "user"
      #|WHERE is_site_admin
      #|  AND status = 'active'
      #|LIMIT 1
    if client.query_opt(admin_sql) is Some(_) {
      return
    }
    let sql =
      #|INSERT INTO invitation (
      #|  kind,
      #|  email,
      #|  name_key,
      #|  display_name,
      #|  password_hash,
      #|  is_site_admin,
      #|  expires_at
      #|)
      #|VALUES (
      #|  'root',
      #|  lower(? || '@localhost'),
      #|  ?,
      #|  ?,
      #|  ?,
      #|  true,
      #|  datetime('now', '+365 days')
      #|)
      #|ON CONFLICT DO NOTHING
    let password_hash = hash_password(root.initial_password)
    let _ = client.execute(sql, params=[
      root.name_key,
      root.name_key,
      root.name_key,
      password_hash,
    ])
  })
}

///|
fn authenticate_user(
  pool : Database,
  name_key : String,
  password : String,
) -> LoginResult? raise {
  pool.with_client(client => {
    client.with_transaction(tx => {
      let user_sql =
        #|SELECT id, name_key, display_name, is_site_admin, password_hash
        #|FROM "user"
        #|WHERE name_key = ?
        #|  AND status = 'active'
      match tx.query_opt(user_sql, params=[name_key]) {
        Some(row) => {
          let password_hash : String = row.get_name("password_hash")
          guard verify_password(password, password_hash) else { return None }
          let user : CurrentUser = {
            id: row.get_name("id"),
            name_key: row.get_name("name_key"),
            display_name: row.get_name("display_name"),
            is_site_admin: row.get_name("is_site_admin"),
          }
          let token = create_session_token(tx, user.id)
          let _ = user
          Some({ token, invitation: None, })
        }
        None => {
          let invitation_sql =
            #|SELECT id, name_key, display_name, password_hash
            #|FROM invitation
            #|WHERE name_key = ?
            #|  AND status = 'sent'
            #|  AND expires_at > datetime('now')
            #|  AND password_hash <> ''
            #|ORDER BY id DESC
            #|LIMIT 1
          match tx.query_opt(invitation_sql, params=[name_key]) {
            None => None
            Some(row) => {
              let password_hash : String = row.get_name("password_hash")
              guard verify_password(password, password_hash) else {
                return None
              }
              let invitation : InvitationLogin = { id: row.get_name("id"), }
              let token = create_invitation_session_token(tx, invitation.id)
              Some({ token, invitation: Some(invitation), })
            }
          }
        }
      }
    })
  })
}

///|
fn lookup_session_user(pool : Database, token : String) -> CurrentUser? raise {
  pool.with_client(client => {
    let sql =
      #|SELECT
      #|  "user".id,
      #|  "user".name_key,
      #|  "user".display_name,
      #|  "user".is_site_admin
      #|FROM session
      #|JOIN "user" ON "user".id = session.user_id
      #|WHERE session.token_hash = ?
      #|  AND session.revoked_at IS NULL
      #|  AND session.expires_at > datetime('now')
      #|  AND "user".status = 'active'
    let token_hash = hash_token(token)
    match client.query_opt(sql, params=[token_hash]) {
      None => None
      Some(row) => {
        let _ = client.execute(
          "UPDATE session SET last_seen_at = datetime('now') WHERE token_hash = ?",
          params=[token_hash],
        )
        Some({
          id: row.get_name("id"),
          name_key: row.get_name("name_key"),
          display_name: row.get_name("display_name"),
          is_site_admin: row.get_name("is_site_admin"),
        })
      }
    }
  })
}

///|
fn lookup_invitation_session(
  pool : Database,
  token : String,
) -> InvitationSession? raise {
  pool.with_client(client => {
    let sql =
      #|SELECT
      #|  invitation_session.id,
      #|  invitation_session.invitation_id,
      #|  invitation.name_key,
      #|  invitation.display_name
      #|FROM invitation_session
      #|JOIN invitation ON invitation.id = invitation_session.invitation_id
      #|WHERE invitation_session.token_hash = ?
      #|  AND invitation_session.revoked_at IS NULL
      #|  AND invitation_session.expires_at > datetime('now')
      #|  AND invitation.status = 'sent'
      #|  AND invitation.expires_at > datetime('now')
    let token_hash = hash_token(token)
    match client.query_opt(sql, params=[token_hash]) {
      None => None
      Some(row) =>
        Some({
          id: row.get_name("invitation_id"),
          name_key: row.get_name("name_key"),
          display_name: row.get_name("display_name"),
        })
    }
  })
}

///|
fn revoke_session(pool : Database, token : String) -> Unit raise {
  pool.with_client(client => {
    let _ = client.execute(
      (
        #|UPDATE session
        #|SET revoked_at = datetime('now')
        #|WHERE token_hash = ?
        #|  AND revoked_at IS NULL
      ),
      params=[hash_token(token)],
    )
    let _ = client.execute(
      (
        #|UPDATE invitation_session
        #|SET revoked_at = datetime('now')
        #|WHERE token_hash = ?
        #|  AND revoked_at IS NULL
      ),
      params=[hash_token(token)],
    )
  })
}

///|
fn accept_invitation(
  pool : Database,
  invitation_session : InvitationSession,
  new_password : String,
) -> LoginResult? raise {
  pool.with_client(client => {
    client.with_transaction(tx => {
      let invitation_sql =
        #|SELECT
        #|  id,
        #|  kind AS kind,
        #|  email,
        #|  name_key,
        #|  display_name,
        #|  is_site_admin,
        #|  team_id,
        #|  team_role AS team_role
        #|FROM invitation
        #|WHERE id = ?
        #|  AND status = 'sent'
        #|  AND expires_at > datetime('now')
      match tx.query_opt(invitation_sql, params=[invitation_session.id]) {
        None => None
        Some(row) => {
          let kind : String = row.get_name("kind")
          let email : String = row.get_name("email")
          let name_key : String = row.get_name("name_key")
          let display_name : String = row.get_name("display_name")
          let is_site_admin : Bool = row.get_name("is_site_admin")
          let team_id : Int64? = row.get_name("team_id")
          let team_role : String? = row.get_name("team_role")
          let password_hash = hash_password(new_password)
          let create_user_sql =
            #|INSERT INTO "user" (
            #|  name_key,
            #|  display_name,
            #|  email,
            #|  password_hash,
            #|  is_site_admin,
            #|  status
            #|)
            #|VALUES (?, ?, ?, ?, ?, 'active')
            #|RETURNING id, name_key, display_name, is_site_admin
          let params : Array[&DbParam] = [
            name_key as &DbParam,
            display_name as &DbParam,
            email as &DbParam,
            password_hash as &DbParam,
            is_site_admin as &DbParam,
          ]
          let user_row = tx.query_one(create_user_sql, params~)
          let user : CurrentUser = {
            id: user_row.get_name("id"),
            name_key: user_row.get_name("name_key"),
            display_name: user_row.get_name("display_name"),
            is_site_admin: user_row.get_name("is_site_admin"),
          }
          if kind == "root" {
            let team_sql =
              #|INSERT INTO team (name_key, display_name, kind)
              #|VALUES (?, ?, 'personal')
              #|ON CONFLICT (name_key) DO UPDATE
              #|SET display_name = excluded.display_name,
              #|    updated_at = datetime('now')
              #|RETURNING id
            let team_row = tx.query_one(team_sql, params=[
              user.name_key,
              user.display_name,
            ])
            let personal_team_id : Int64 = team_row.get_name("id")
            let member_params : Array[&DbParam] = [
              personal_team_id as &DbParam,
              user.id as &DbParam,
            ]
            let _ = tx.execute(
              (
                #|INSERT INTO team_member (team_id, user_id, role)
                #|VALUES (?, ?, 'owner')
                #|ON CONFLICT (team_id, user_id) DO UPDATE
                #|SET role = excluded.role
              ),
              params=member_params,
            )
          } else {
            let member_params : Array[&DbParam] = [
              team_id.unwrap() as &DbParam,
              user.id as &DbParam,
              team_role.unwrap() as &DbParam,
            ]
            let _ = tx.execute(
              (
                #|INSERT INTO team_member (team_id, user_id, role)
                #|VALUES (?, ?, ?)
                #|ON CONFLICT (team_id, user_id) DO UPDATE
                #|SET role = excluded.role
              ),
              params=member_params,
            )
          }
          let _ = tx.execute(
            (
              #|UPDATE invitation
              #|SET status = 'accepted',
              #|    accepted_at = datetime('now'),
              #|    accepted_user_id = ?
              #|WHERE id = ?
            ),
            params=[user.id, invitation_session.id],
          )
          let _ = tx.execute(
            (
              #|UPDATE invitation_session
              #|SET revoked_at = datetime('now')
              #|WHERE invitation_id = ?
            ),
            params=[invitation_session.id],
          )
          let token = create_session_token(tx, user.id)
          let _ = user
          Some({ token, invitation: None, })
        }
      }
    })
  })
}

///|
fn create_team(
  pool : Database,
  actor : CurrentUser,
  name_key : String,
  display_name : String,
) -> Bool raise {
  guard actor.is_site_admin else {
    raise Unauthorized(message="site admin required")
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      match
        tx.query_opt("SELECT id FROM team WHERE name_key = ?", params=[name_key]) {
        Some(_) => false
        None => {
          let _ = tx.execute(
            "INSERT INTO team (name_key, display_name, kind) VALUES (?, ?, 'org')",
            params=[name_key, display_name],
          )
          let team_row = tx.query_one(
            "SELECT id FROM team WHERE name_key = ?",
            params=[name_key],
          )
          let team_id : Int64 = team_row.get_name("id")
          let sql =
            #|INSERT INTO team_member (team_id, user_id, role)
            #|VALUES (?, ?, 'owner')
          let params : Array[&DbParam] = [
            team_id as &DbParam,
            actor.id as &DbParam,
          ]
          let _ = tx.execute(sql, params~)
          true
        }
      }
    })
  })
}

///|
fn list_teams(pool : Database, actor : CurrentUser) -> Array[TeamSummary] raise {
  pool.with_client(client => {
    let rows = if actor.is_site_admin {
      client.query_all(
        (
          #|SELECT
          #|  team.id,
          #|  team.name_key,
          #|  team.display_name,
          #|  team.kind AS kind,
          #|  team_member.role AS role
          #|FROM team
          #|LEFT JOIN team_member
          #|  ON team_member.team_id = team.id
          #| AND team_member.user_id = ?
          #|WHERE team.kind = 'org'
          #|ORDER BY team.name_key
        ),
        params=[actor.id],
      )
    } else {
      client.query_all(
        (
          #|SELECT
          #|  team.id,
          #|  team.name_key,
          #|  team.display_name,
          #|  team.kind AS kind,
          #|  team_member.role AS role
          #|FROM team
          #|JOIN team_member ON team_member.team_id = team.id
          #|WHERE team_member.user_id = ?
          #|  AND team.kind = 'org'
          #|ORDER BY team.name_key
        ),
        params=[actor.id],
      )
    }
    rows.map(row => {
      id: row.get_name("id"),
      name_key: row.get_name("name_key"),
      display_name: row.get_name("display_name"),
      kind: row.get_name("kind"),
      role: row.get_name("role"),
    })
  })
}

///|
fn get_team_by_name_key(
  pool : Database,
  name_key : String,
) -> TeamSummary? raise {
  pool.with_client(client => {
    match
      client.query_opt(
        (
          #|SELECT id, name_key, display_name, kind AS kind
          #|FROM team
          #|WHERE name_key = ?
        ),
        params=[name_key],
      ) {
      None => None
      Some(row) =>
        Some({
          id: row.get_name("id"),
          name_key: row.get_name("name_key"),
          display_name: row.get_name("display_name"),
          kind: row.get_name("kind"),
          role: None,
        })
    }
  })
}

///|
fn team_role(
  pool : Database,
  actor : CurrentUser,
  team_id : Int64,
) -> String? raise {
  pool.with_client(client => {
    match
      client.query_opt(
        (
          #|SELECT role AS role
          #|FROM team_member
          #|WHERE team_id = ?
          #|  AND user_id = ?
        ),
        params=[team_id, actor.id],
      ) {
      None => None
      Some(row) => Some(row.get_name("role"))
    }
  })
}

///|
fn can_manage_team(
  pool : Database,
  actor : CurrentUser,
  team_id : Int64,
) -> Bool raise {
  if actor.is_site_admin {
    true
  } else {
    match team_role(pool, actor, team_id) {
      Some("owner" | "admin") => true
      _ => false
    }
  }
}

///|
fn list_team_members(
  pool : Database,
  team : TeamSummary,
) -> Array[TeamMemberSummary] raise {
  pool.with_client(client => {
    client
    .query_all(
      (
        #|SELECT
        #|  "user".name_key,
        #|  "user".display_name,
        #|  "user".email,
        #|  team_member.role AS role
        #|FROM team_member
        #|JOIN "user" ON "user".id = team_member.user_id
        #|WHERE team_member.team_id = ?
        #|ORDER BY
        #|  CASE team_member.role
        #|    WHEN 'owner' THEN 0
        #|    WHEN 'admin' THEN 1
        #|    ELSE 2
        #|  END,
        #|  "user".name_key
      ),
      params=[team.id],
    )
    .map(row => {
      name_key: row.get_name("name_key"),
      display_name: row.get_name("display_name"),
      email: row.get_name("email"),
      role: row.get_name("role"),
    })
  })
}

///|
fn list_invitations(
  pool : Database,
  team : TeamSummary,
) -> Array[InvitationSummary] raise {
  pool.with_client(client => {
    client
    .query_all(
      (
        #|SELECT
        #|  invitation.id,
        #|  invitation.email,
        #|  invitation.name_key,
        #|  invitation.display_name,
        #|  invitation.kind AS kind,
        #|  invitation.team_role AS role,
        #|  invitation.status AS status,
        #|  (SELECT status FROM email_outbox
        #|   WHERE email_outbox.invitation_id = invitation.id
        #|   ORDER BY id DESC LIMIT 1) AS email_status,
        #|  (SELECT sent_at FROM email_outbox
        #|   WHERE email_outbox.invitation_id = invitation.id
        #|   ORDER BY id DESC LIMIT 1) AS email_sent_at,
        #|  (SELECT last_error FROM email_outbox
        #|   WHERE email_outbox.invitation_id = invitation.id
        #|   ORDER BY id DESC LIMIT 1) AS email_last_error
        #|FROM invitation
        #|WHERE invitation.team_id = ?
        #|ORDER BY invitation.id DESC
      ),
      params=[team.id],
    )
    .map(row => {
      id: row.get_name("id"),
      email: row.get_name("email"),
      name_key: row.get_name("name_key"),
      display_name: row.get_name("display_name"),
      role: row.get_name("role"),
      status: row.get_name("status"),
      email_status: row.get_name("email_status"),
      email_sent_at: row.get_name("email_sent_at"),
      email_last_error: row.get_name("email_last_error"),
    })
  })
}

///|
fn invite_team_member(
  pool : Database,
  actor : CurrentUser,
  team : TeamSummary,
  email : String,
  name_key : String,
  display_name : String,
  role : String,
) -> Int64 raise {
  guard can_manage_team(pool, actor, team.id) else {
    raise Unauthorized(message="team admin required")
  }
  let one_time_password = generate_one_time_password(pool)
  pool.with_client(client => {
    client.with_transaction(tx => {
      let conflict_sql =
        #|SELECT id
        #|FROM "user"
        #|WHERE name_key = ? OR email = ?
        #|UNION ALL
        #|SELECT id
        #|FROM invitation
        #|WHERE status = 'sent'
        #|  AND (name_key = ? OR email = ?)
        #|LIMIT 1
      if tx.query_opt(conflict_sql, params=[name_key, email]) is Some(_) {
        raise BadRequest(message="user name_key or email is already in use")
      }
      let password_hash = hash_password(one_time_password)
      let params : Array[&DbParam] = [
        email as &DbParam,
        name_key as &DbParam,
        display_name as &DbParam,
        password_hash as &DbParam,
        team.id as &DbParam,
        role as &DbParam,
        actor.id as &DbParam,
      ]
      let invitation_row = tx.query_one(
        (
          #|INSERT INTO invitation (
          #|  kind,
          #|  email,
          #|  name_key,
          #|  display_name,
          #|  password_hash,
          #|  is_site_admin,
          #|  team_id,
          #|  team_role,
          #|  invited_by_user_id
          #|)
          #|VALUES (
          #|  'team_member',
          #|  ?,
          #|  ?,
          #|  ?,
          #|  ?,
          #|  false,
          #|  ?,
          #|  ?,
          #|  ?
          #|)
          #|RETURNING id
        ),
        params~,
      )
      let invitation_id : Int64 = invitation_row.get_name("id")
      let subject = "You have been invited to \{team.display_name} on moonhub"
      let body = invitation_email_body(team, name_key, role, one_time_password)
      let email_params : Array[&DbParam] = [
        invitation_id as &DbParam,
        email as &DbParam,
        subject as &DbParam,
        body as &DbParam,
      ]
      let _ = tx.execute(
        (
          #|INSERT INTO email_outbox (
          #|  invitation_id,
          #|  to_email,
          #|  subject,
          #|  body,
          #|  template
          #|)
          #|VALUES (
          #|  ?,
          #|  ?,
          #|  ?,
          #|  ?,
          #|  'team_invitation'
          #|)
        ),
        params=email_params,
      )
      invitation_id
    })
  })
}

///|
fn revoke_invitation(
  pool : Database,
  actor : CurrentUser,
  team_id : Int64,
  invitation_id : Int64,
) -> Bool raise {
  let row = pool.with_client(client => {
    client.query_opt(
      (
        #|SELECT team_id
        #|FROM invitation
        #|WHERE id = ?
        #|  AND team_id = ?
        #|  AND kind = 'team_member'
      ),
      params=[invitation_id, team_id],
    )
  })
  let team_id : Int64 = match row {
    Some(row) => row.get_name("team_id")
    None => raise NotFound(message="invitation not found")
  }
  guard can_manage_team(pool, actor, team_id) else {
    raise Unauthorized(message="team admin required")
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      let changed = tx.execute(
          (
            #|UPDATE invitation
            #|SET status = 'revoked',
            #|    revoked_at = datetime('now')
            #|WHERE id = ?
            #|  AND status = 'sent'
          ),
          params=[invitation_id],
        ) ==
        1
      if changed {
        let _ = tx.execute(
          (
            #|UPDATE invitation_session
            #|SET revoked_at = datetime('now')
            #|WHERE invitation_id = ?
            #|  AND revoked_at IS NULL
          ),
          params=[invitation_id],
        )
      }
      changed
    })
  })
}

///|
fn resend_invitation_email(
  pool : Database,
  actor : CurrentUser,
  team_id : Int64,
  invitation_id : Int64,
) -> Bool raise {
  guard can_manage_team(pool, actor, team_id) else {
    raise Unauthorized(message="team admin required")
  }
  pool.with_client(client => {
    let changed = client.execute(
      (
        #|UPDATE email_outbox
        #|SET status = 'pending',
        #|    attempt_count = 0,
        #|    next_attempt_at = datetime('now'),
        #|    locked_at = NULL,
        #|    locked_by = NULL,
        #|    last_error = NULL,
        #|    provider_message_id = NULL,
        #|    sent_at = NULL
        #|WHERE id = (
        #|  SELECT email_outbox.id
        #|  FROM email_outbox
        #|  JOIN invitation ON invitation.id = email_outbox.invitation_id
        #|  WHERE invitation.id = ?
        #|    AND invitation.team_id = ?
        #|    AND invitation.kind = 'team_member'
        #|    AND invitation.status = 'sent'
        #|    AND email_outbox.status IN ('pending', 'failed')
        #|    AND email_outbox.last_error IS NOT NULL
        #|  ORDER BY email_outbox.id DESC
        #|  LIMIT 1
        #|)
      ),
      params=[invitation_id, team_id],
    )
    guard changed == 1 else {
      raise NotFound(message="failed invitation email not found")
    }
    true
  })
}

///|
fn generate_one_time_password(_pool : Database) -> String {
  random_hex(18)
}

///|
fn create_session_token(
  tx : DbTransaction,
  user_id : Int64,
) -> String raise @moondb.DbError {
  let token = random_hex(32)
  let _ = tx.execute(
    (
      #|INSERT INTO session (user_id, token_hash, expires_at, last_seen_at)
      #|VALUES (?, ?, datetime('now', '+30 days'), datetime('now'))
    ),
    params=[user_id, hash_token(token)],
  )
  token
}

///|
fn create_invitation_session_token(
  tx : DbTransaction,
  invitation_id : Int64,
) -> String raise @moondb.DbError {
  let token = random_hex(32)
  let _ = tx.execute(
    (
      #|INSERT INTO invitation_session (invitation_id, token_hash, expires_at)
      #|VALUES (?, ?, datetime('now', '+2 hours'))
    ),
    params=[invitation_id, hash_token(token)],
  )
  token
}

///|
fn invitation_email_body(
  team : TeamSummary,
  name_key : String,
  role : String,
  one_time_password : String,
) -> String {
  (
    $|You have been invited to moonhub.
    $|
    $|Team: \{team.display_name} (\{team.name_key})
    $|Role: \{role}
    $|Username: \{name_key}
    $|One-time password: \{one_time_password}
    $|
    $|Sign in and set your password before using moonhub.
  )
}
