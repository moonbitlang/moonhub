///|
extenum @moonback.TypedBox += {
  DbPool(@pgpool.Pool)
}

///|
let config_db_pool : @moonback.TypedKey[@pgpool.Pool] = TypedKey(
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
fn db_pool(ctx : @moonback.ModuleContext) -> @pgpool.Pool {
  match ctx.config().get_custom(config_db_pool) {
    Some(pool) => pool
    None => abort("missing moonhub db pool")
  }
}

///|
fn new_db_pool(
  config : DbConfig,
  group : @async.TaskGroup[Unit],
) -> @pgpool.Pool raise {
  let pool_config = @pgpool.PoolConfig::new(config.pool_size)
  @pgpool.Config::new(
    config.host,
    port=config.port,
    user=config.user,
    dbname=config.name,
    password?=config.password,
    ssl_mode=Disable,
    application_name="moonhub",
    pool=pool_config,
  ).create_pool(group)
}

///|
async fn initialize_db(pool : @pgpool.Pool) -> Unit {
  pool.with_client(client => {
    let table_row = client.query_one(
      "SELECT to_regclass('public.\"user\"')::text AS table_name",
    )
    let table_name : String? = table_row.get_name("table_name")
    if table_name is None {
      let sql = @fs.read_file("db/base.sql").text()
      client.batch_execute(sql)
    }
  })
}

///|
async fn ensure_root_invitation(
  pool : @pgpool.Pool,
  root : RootUserConfig,
) -> Unit {
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
      #|  lower($1 || '@localhost'),
      #|  $1,
      #|  $1,
      #|  crypt($2, gen_salt('bf')),
      #|  true,
      #|  now() + interval '365 days'
      #|)
      #|ON CONFLICT DO NOTHING
    let _ = client.execute(sql, params=[root.name_key, root.initial_password])
  })
}

///|
async fn authenticate_user(
  pool : @pgpool.Pool,
  name_key : String,
  password : String,
) -> LoginResult? {
  pool.with_client(client => {
    client.with_transaction(tx => {
      let user_sql =
        #|SELECT id, name_key, display_name, is_site_admin
        #|FROM "user"
        #|WHERE name_key = $1
        #|  AND status = 'active'
        #|  AND password_hash = crypt($2, password_hash)
      match tx.query_opt(user_sql, params=[name_key, password]) {
        Some(row) => {
          let user : CurrentUser = {
            id: row.get_name("id"),
            name_key: row.get_name("name_key"),
            display_name: row.get_name("display_name"),
            is_site_admin: row.get_name("is_site_admin"),
          }
          let token = create_session_token(tx, user.id)
          let _ = user
          Some({ token, invitation: None })
        }
        None => {
          let invitation_sql =
            #|SELECT id, name_key, display_name
            #|FROM invitation
            #|WHERE name_key = $1
            #|  AND status = 'sent'
            #|  AND expires_at > now()
            #|  AND password_hash = crypt($2, password_hash)
            #|ORDER BY id DESC
            #|LIMIT 1
          match tx.query_opt(invitation_sql, params=[name_key, password]) {
            None => None
            Some(row) => {
              let invitation : InvitationLogin = { id: row.get_name("id") }
              let token = create_invitation_session_token(tx, invitation.id)
              Some({ token, invitation: Some(invitation) })
            }
          }
        }
      }
    })
  })
}

///|
async fn lookup_session_user(
  pool : @pgpool.Pool,
  token : String,
) -> CurrentUser? {
  pool.with_client(client => {
    let sql =
      #|UPDATE session
      #|SET last_seen_at = now()
      #|FROM "user"
      #|WHERE session.user_id = "user".id
      #|  AND session.token_hash = encode(digest($1, 'sha256'), 'hex')
      #|  AND session.revoked_at IS NULL
      #|  AND session.expires_at > now()
      #|  AND "user".status = 'active'
      #|RETURNING
      #|  "user".id,
      #|  "user".name_key,
      #|  "user".display_name,
      #|  "user".is_site_admin
    match client.query_opt(sql, params=[token]) {
      None => None
      Some(row) =>
        Some({
          id: row.get_name("id"),
          name_key: row.get_name("name_key"),
          display_name: row.get_name("display_name"),
          is_site_admin: row.get_name("is_site_admin"),
        })
    }
  })
}

///|
async fn lookup_invitation_session(
  pool : @pgpool.Pool,
  token : String,
) -> InvitationSession? {
  pool.with_client(client => {
    let sql =
      #|SELECT
      #|  invitation_session.id,
      #|  invitation_session.invitation_id,
      #|  invitation.name_key,
      #|  invitation.display_name
      #|FROM invitation_session
      #|JOIN invitation ON invitation.id = invitation_session.invitation_id
      #|WHERE invitation_session.token_hash = encode(digest($1, 'sha256'), 'hex')
      #|  AND invitation_session.revoked_at IS NULL
      #|  AND invitation_session.expires_at > now()
      #|  AND invitation.status = 'sent'
      #|  AND invitation.expires_at > now()
    match client.query_opt(sql, params=[token]) {
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
async fn revoke_session(pool : @pgpool.Pool, token : String) -> Unit {
  pool.with_client(client => {
    let _ = client.execute(
      (
        #|UPDATE session
        #|SET revoked_at = now()
        #|WHERE token_hash = encode(digest($1, 'sha256'), 'hex')
        #|  AND revoked_at IS NULL
      ),
      params=[token],
    )
    let _ = client.execute(
      (
        #|UPDATE invitation_session
        #|SET revoked_at = now()
        #|WHERE token_hash = encode(digest($1, 'sha256'), 'hex')
        #|  AND revoked_at IS NULL
      ),
      params=[token],
    )
  })
}

///|
async fn accept_invitation(
  pool : @pgpool.Pool,
  invitation_session : InvitationSession,
  new_password : String,
) -> LoginResult? {
  pool.with_client(client => {
    client.with_transaction(tx => {
      let invitation_sql =
        #|SELECT
        #|  id,
        #|  kind::text AS kind,
        #|  email,
        #|  name_key,
        #|  display_name,
        #|  is_site_admin,
        #|  team_id,
        #|  team_role::text AS team_role
        #|FROM invitation
        #|WHERE id = $1
        #|  AND status = 'sent'
        #|  AND expires_at > now()
        #|FOR UPDATE
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
          let create_user_sql =
            #|INSERT INTO "user" (
            #|  name_key,
            #|  display_name,
            #|  email,
            #|  password_hash,
            #|  is_site_admin,
            #|  status
            #|)
            #|VALUES ($1, $2, $3, crypt($4, gen_salt('bf')), $5, 'active')
            #|RETURNING id, name_key, display_name, is_site_admin
          let params : Array[&@client.ToSql] = [
            name_key as &@client.ToSql,
            display_name as &@client.ToSql,
            email as &@client.ToSql,
            new_password as &@client.ToSql,
            is_site_admin as &@client.ToSql,
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
              #|VALUES ($1, $2, 'personal')
              #|ON CONFLICT (name_key) DO UPDATE
              #|SET display_name = EXCLUDED.display_name,
              #|    updated_at = now()
              #|RETURNING id
            let team_row = tx.query_one(team_sql, params=[
              user.name_key,
              user.display_name,
            ])
            let personal_team_id : Int64 = team_row.get_name("id")
            let member_params : Array[&@client.ToSql] = [
              personal_team_id as &@client.ToSql,
              user.id as &@client.ToSql,
            ]
            let _ = tx.execute(
              (
                #|INSERT INTO team_member (team_id, user_id, role)
                #|VALUES ($1, $2, 'owner')
                #|ON CONFLICT (team_id, user_id) DO UPDATE
                #|SET role = EXCLUDED.role
              ),
              params=member_params,
            )
          } else {
            let member_params : Array[&@client.ToSql] = [
              team_id.unwrap() as &@client.ToSql,
              user.id as &@client.ToSql,
              team_role.unwrap() as &@client.ToSql,
            ]
            let _ = tx.execute(
              (
                #|INSERT INTO team_member (team_id, user_id, role)
                #|VALUES ($1, $2, $3::text::team_member_role)
                #|ON CONFLICT (team_id, user_id) DO UPDATE
                #|SET role = EXCLUDED.role
              ),
              params=member_params,
            )
          }
          let _ = tx.execute(
            (
              #|UPDATE invitation
              #|SET status = 'accepted',
              #|    accepted_at = now(),
              #|    accepted_user_id = $2
              #|WHERE id = $1
            ),
            params=[invitation_session.id, user.id],
          )
          let _ = tx.execute(
            (
              #|UPDATE invitation_session
              #|SET revoked_at = now()
              #|WHERE invitation_id = $1
            ),
            params=[invitation_session.id],
          )
          let token = create_session_token(tx, user.id)
          let _ = user
          Some({ token, invitation: None })
        }
      }
    })
  })
}

///|
async fn create_team(
  pool : @pgpool.Pool,
  actor : CurrentUser,
  name_key : String,
  display_name : String,
) -> Bool {
  guard actor.is_site_admin else {
    raise Unauthorized(message="site admin required")
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      match
        tx.query_opt("SELECT id FROM team WHERE name_key = $1", params=[
          name_key,
        ]) {
        Some(_) => false
        None => {
          let sql =
            #|WITH inserted_team AS (
            #|  INSERT INTO team (name_key, display_name, kind)
            #|  VALUES ($1, $2, 'org')
            #|  RETURNING id
            #|)
            #|INSERT INTO team_member (team_id, user_id, role)
            #|SELECT inserted_team.id, $3, 'owner'
            #|FROM inserted_team
          let params : Array[&@client.ToSql] = [
            name_key as &@client.ToSql,
            display_name as &@client.ToSql,
            actor.id as &@client.ToSql,
          ]
          let _ = tx.execute(sql, params~)
          true
        }
      }
    })
  })
}

///|
async fn list_teams(
  pool : @pgpool.Pool,
  actor : CurrentUser,
) -> Array[TeamSummary] {
  pool.with_client(client => {
    let rows = if actor.is_site_admin {
      client.query_all(
        (
          #|SELECT
          #|  team.id,
          #|  team.name_key,
          #|  team.display_name,
          #|  team.kind::text AS kind,
          #|  team_member.role::text AS role
          #|FROM team
          #|LEFT JOIN team_member
          #|  ON team_member.team_id = team.id
          #| AND team_member.user_id = $1
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
          #|  team.kind::text AS kind,
          #|  team_member.role::text AS role
          #|FROM team
          #|JOIN team_member ON team_member.team_id = team.id
          #|WHERE team_member.user_id = $1
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
async fn get_team_by_name_key(
  pool : @pgpool.Pool,
  name_key : String,
) -> TeamSummary? {
  pool.with_client(client => {
    match
      client.query_opt(
        (
          #|SELECT id, name_key, display_name, kind::text AS kind
          #|FROM team
          #|WHERE name_key = $1
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
async fn team_role(
  pool : @pgpool.Pool,
  actor : CurrentUser,
  team_id : Int64,
) -> String? {
  pool.with_client(client => {
    match
      client.query_opt(
        (
          #|SELECT role::text AS role
          #|FROM team_member
          #|WHERE team_id = $1
          #|  AND user_id = $2
        ),
        params=[team_id, actor.id],
      ) {
      None => None
      Some(row) => Some(row.get_name("role"))
    }
  })
}

///|
async fn can_manage_team(
  pool : @pgpool.Pool,
  actor : CurrentUser,
  team_id : Int64,
) -> Bool {
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
async fn list_team_members(
  pool : @pgpool.Pool,
  team : TeamSummary,
) -> Array[TeamMemberSummary] {
  pool.with_client(client => {
    client
    .query_all(
      (
        #|SELECT
        #|  "user".name_key,
        #|  "user".display_name,
        #|  "user".email,
        #|  team_member.role::text AS role
        #|FROM team_member
        #|JOIN "user" ON "user".id = team_member.user_id
        #|WHERE team_member.team_id = $1
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
async fn list_invitations(
  pool : @pgpool.Pool,
  team : TeamSummary,
) -> Array[InvitationSummary] {
  pool.with_client(client => {
    client
    .query_all(
      (
        #|SELECT
        #|  invitation.id,
        #|  invitation.email,
        #|  invitation.name_key,
        #|  invitation.display_name,
        #|  invitation.kind::text AS kind,
        #|  invitation.team_role::text AS role,
        #|  invitation.status::text AS status,
        #|  email_outbox.status::text AS email_status,
        #|  email_outbox.sent_at::text AS email_sent_at,
        #|  email_outbox.last_error AS email_last_error
        #|FROM invitation
        #|LEFT JOIN LATERAL (
        #|  SELECT status, sent_at, last_error
        #|  FROM email_outbox
        #|  WHERE email_outbox.invitation_id = invitation.id
        #|  ORDER BY id DESC
        #|  LIMIT 1
        #|) email_outbox ON true
        #|WHERE invitation.team_id = $1
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
async fn invite_team_member(
  pool : @pgpool.Pool,
  actor : CurrentUser,
  team : TeamSummary,
  email : String,
  name_key : String,
  display_name : String,
  role : String,
) -> Int64 {
  guard can_manage_team(pool, actor, team.id) else {
    raise Unauthorized(message="team admin required")
  }
  let one_time_password = generate_one_time_password(pool)
  pool.with_client(client => {
    client.with_transaction(tx => {
      let conflict_sql =
        #|SELECT id
        #|FROM "user"
        #|WHERE name_key = $1 OR email = $2
        #|UNION ALL
        #|SELECT id
        #|FROM invitation
        #|WHERE status = 'sent'
        #|  AND (name_key = $1 OR email = $2)
        #|LIMIT 1
      if tx.query_opt(conflict_sql, params=[name_key, email]) is Some(_) {
        raise BadRequest(message="user name_key or email is already in use")
      }
      let params : Array[&@client.ToSql] = [
        email as &@client.ToSql,
        name_key as &@client.ToSql,
        display_name as &@client.ToSql,
        one_time_password as &@client.ToSql,
        team.id as &@client.ToSql,
        role as &@client.ToSql,
        actor.id as &@client.ToSql,
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
          #|  $1,
          #|  $2,
          #|  $3,
          #|  crypt($4, gen_salt('bf')),
          #|  false,
          #|  $5,
          #|  $6::text::team_member_role,
          #|  $7
          #|)
          #|RETURNING id
        ),
        params~,
      )
      let invitation_id : Int64 = invitation_row.get_name("id")
      let subject = "You have been invited to \{team.display_name} on moonhub"
      let body = invitation_email_body(team, name_key, role, one_time_password)
      let email_params : Array[&@client.ToSql] = [
        invitation_id as &@client.ToSql,
        email as &@client.ToSql,
        subject as &@client.ToSql,
        body as &@client.ToSql,
        team.name_key as &@client.ToSql,
        team.display_name as &@client.ToSql,
        name_key as &@client.ToSql,
        role as &@client.ToSql,
      ]
      let _ = tx.execute(
        (
          #|INSERT INTO email_outbox (
          #|  invitation_id,
          #|  to_email,
          #|  subject,
          #|  body,
          #|  template,
          #|  payload
          #|)
          #|VALUES (
          #|  $1,
          #|  $2,
          #|  $3,
          #|  $4,
          #|  'team_invitation',
          #|  jsonb_build_object(
          #|    'team_name_key', $5::text,
          #|    'team_display_name', $6::text,
          #|    'invitee_name_key', $7::text,
          #|    'role', $8::text
          #|  )
          #|)
        ),
        params=email_params,
      )
      invitation_id
    })
  })
}

///|
async fn revoke_invitation(
  pool : @pgpool.Pool,
  actor : CurrentUser,
  team_id : Int64,
  invitation_id : Int64,
) -> Bool {
  let row = pool.with_client(client => {
    client.query_opt(
      (
        #|SELECT team_id
        #|FROM invitation
        #|WHERE id = $1
        #|  AND team_id = $2
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
            #|    revoked_at = now()
            #|WHERE id = $1
            #|  AND status = 'sent'
          ),
          params=[invitation_id],
        ) ==
        1
      if changed {
        let _ = tx.execute(
          (
            #|UPDATE invitation_session
            #|SET revoked_at = now()
            #|WHERE invitation_id = $1
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
async fn resend_invitation_email(
  pool : @pgpool.Pool,
  actor : CurrentUser,
  team_id : Int64,
  invitation_id : Int64,
) -> Bool {
  guard can_manage_team(pool, actor, team_id) else {
    raise Unauthorized(message="team admin required")
  }
  pool.with_client(client => {
    let changed = client.execute(
      (
        #|UPDATE email_outbox
        #|SET status = 'pending',
        #|    attempt_count = 0,
        #|    next_attempt_at = now(),
        #|    locked_at = NULL,
        #|    locked_by = NULL,
        #|    last_error = NULL,
        #|    provider_message_id = NULL,
        #|    sent_at = NULL
        #|WHERE id = (
        #|  SELECT email_outbox.id
        #|  FROM email_outbox
        #|  JOIN invitation ON invitation.id = email_outbox.invitation_id
        #|  WHERE invitation.id = $1
        #|    AND invitation.team_id = $2
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
async fn generate_one_time_password(pool : @pgpool.Pool) -> String {
  pool.with_client(client => {
    let row = client.query_one(
      "SELECT encode(gen_random_bytes(18), 'base64') AS password",
    )
    row.get_name("password")
  })
}

///|
async fn create_session_token(
  tx : @pgpool.Transaction,
  user_id : Int64,
) -> String {
  let token_sql =
    #|WITH generated AS (
    #|  SELECT encode(gen_random_bytes(32), 'hex') AS token
    #|), inserted AS (
    #|  INSERT INTO session (user_id, token_hash, expires_at, last_seen_at)
    #|  SELECT $1, encode(digest(generated.token, 'sha256'), 'hex'), now() + interval '30 days', now()
    #|  FROM generated
    #|  RETURNING id
    #|)
    #|SELECT generated.token
    #|FROM generated, inserted
  let row = tx.query_one(token_sql, params=[user_id])
  row.get_name("token")
}

///|
async fn create_invitation_session_token(
  tx : @pgpool.Transaction,
  invitation_id : Int64,
) -> String {
  let token_sql =
    #|WITH generated AS (
    #|  SELECT encode(gen_random_bytes(32), 'hex') AS token
    #|), inserted AS (
    #|  INSERT INTO invitation_session (invitation_id, token_hash, expires_at)
    #|  SELECT $1, encode(digest(generated.token, 'sha256'), 'hex'), now() + interval '2 hours'
    #|  FROM generated
    #|  RETURNING id
    #|)
    #|SELECT generated.token
    #|FROM generated, inserted
  let row = tx.query_one(token_sql, params=[invitation_id])
  row.get_name("token")
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
