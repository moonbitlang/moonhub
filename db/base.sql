-- Schema 38 baseline. initialize_db owns the transaction and user_version.
-- Incremental migrations after this baseline start at 039.

CREATE TABLE "user" (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name_key TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  email TEXT UNIQUE,
  password_hash TEXT NOT NULL,
  is_site_admin INTEGER NOT NULL DEFAULT 0 CHECK (is_site_admin IN (0, 1)),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  CHECK (name_key <> 'assets'),
  CHECK (display_name <> ''),
  CHECK (email IS NULL OR (email = lower(email) AND email <> '')),
  CHECK (password_hash <> '')
);

CREATE TABLE team (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name_key TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('personal', 'org')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  CHECK (name_key <> 'assets'),
  CHECK (display_name <> '')
);

CREATE TABLE team_member (
  team_id INTEGER NOT NULL REFERENCES team(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (team_id, user_id)
);

CREATE INDEX team_member_user_id_index ON team_member (user_id);

CREATE TABLE invitation (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK (kind IN ('root', 'team_member')),
  email TEXT NOT NULL,
  name_key TEXT NOT NULL,
  display_name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  is_site_admin INTEGER NOT NULL DEFAULT 0 CHECK (is_site_admin IN (0, 1)),
  team_id INTEGER REFERENCES team(id) ON DELETE CASCADE,
  team_role TEXT CHECK (team_role IS NULL OR team_role IN ('admin', 'member')),
  invited_by_user_id INTEGER REFERENCES "user"(id) ON DELETE RESTRICT,
  accepted_user_id INTEGER REFERENCES "user"(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'sent'
    CHECK (status IN ('sent', 'accepted', 'revoked', 'expired')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL DEFAULT (datetime('now', '+7 days')),
  accepted_at TEXT,
  revoked_at TEXT,
  CHECK (email = lower(email) AND email <> ''),
  CHECK (name_key <> 'assets'),
  CHECK (display_name <> ''),
  CHECK (password_hash <> ''),
  CHECK (
    (kind = 'root' AND is_site_admin = 1 AND team_id IS NULL AND
      team_role IS NULL AND invited_by_user_id IS NULL)
    OR
    (kind = 'team_member' AND is_site_admin = 0 AND team_id IS NOT NULL AND
      team_role IN ('admin', 'member') AND invited_by_user_id IS NOT NULL)
  )
);

CREATE INDEX invitation_team_id_index ON invitation (team_id);

CREATE INDEX invitation_email_index ON invitation (email);

CREATE INDEX invitation_accepted_user_id_index ON invitation (accepted_user_id);

CREATE UNIQUE INDEX invitation_sent_name_key_index
  ON invitation (name_key) WHERE status = 'sent';

CREATE UNIQUE INDEX invitation_sent_email_index
  ON invitation (email) WHERE status = 'sent';

CREATE TABLE session (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  last_seen_at TEXT,
  CHECK (token_hash <> ''),
  CHECK (revoked_at IS NULL OR revoked_at >= created_at)
);

CREATE INDEX session_user_id_index ON session (user_id);

CREATE INDEX session_expires_at_index ON session (expires_at);

CREATE TABLE invitation_session (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  invitation_id INTEGER NOT NULL REFERENCES invitation(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  CHECK (token_hash <> ''),
  CHECK (revoked_at IS NULL OR revoked_at >= created_at)
);

CREATE INDEX invitation_session_invitation_id_index
  ON invitation_session (invitation_id);

CREATE TABLE email_outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  invitation_id INTEGER REFERENCES invitation(id) ON DELETE SET NULL,
  to_email TEXT NOT NULL,
  subject TEXT NOT NULL,
  body TEXT NOT NULL,
  template TEXT NOT NULL DEFAULT 'plain',
  payload TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'sent', 'failed')),
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_attempt_at TEXT NOT NULL DEFAULT (datetime('now')),
  locked_at TEXT,
  locked_by TEXT,
  last_error TEXT,
  provider_message_id TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  sent_at TEXT,
  password_reset_id INTEGER
  REFERENCES password_reset(id) ON DELETE SET NULL,
  notification_id INTEGER REFERENCES collaboration_notification(id) ON DELETE CASCADE,
  CHECK (to_email = lower(to_email) AND to_email <> ''),
  CHECK (subject <> ''),
  CHECK (body <> ''),
  CHECK (template <> ''),
  CHECK (locked_by IS NULL OR locked_by <> ''),
  CHECK (last_error IS NULL OR last_error <> ''),
  CHECK (provider_message_id IS NULL OR provider_message_id <> '')
);

CREATE INDEX email_outbox_to_email_index ON email_outbox (to_email);

CREATE INDEX email_outbox_invitation_id_index ON email_outbox (invitation_id);

CREATE INDEX email_outbox_sent_at_index ON email_outbox (sent_at);

CREATE INDEX email_outbox_pending_index
  ON email_outbox (next_attempt_at, id) WHERE status = 'pending';

CREATE TABLE repository (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  team_id INTEGER NOT NULL REFERENCES team(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  display_name TEXT,
  visibility TEXT NOT NULL DEFAULT 'private'
    CHECK (visibility IN ('public', 'private')),
  git_path TEXT,
  default_branch TEXT NOT NULL DEFAULT 'HEAD',
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  ready INTEGER NOT NULL DEFAULT 1
  CHECK (ready IN (0, 1)),
  pipeline_push_enabled INTEGER NOT NULL DEFAULT 0
  CHECK (pipeline_push_enabled IN (0, 1)),
  UNIQUE (team_id, name),
  CHECK (name NOT IN ('.', '..')),
  CHECK (display_name IS NULL OR display_name <> ''),
  CHECK (git_path IS NULL OR git_path <> ''),
  CHECK (default_branch <> '')
);

CREATE INDEX repository_team_id_index ON repository (team_id);

CREATE INDEX repository_visibility_index ON repository (visibility);

CREATE TABLE ssh_key (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  title TEXT NOT NULL CHECK (title <> ''),
  public_key TEXT NOT NULL UNIQUE CHECK (public_key <> ''),
  fingerprint TEXT NOT NULL UNIQUE CHECK (fingerprint <> ''),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_used_at TEXT,
  revoked_at TEXT
);

CREATE INDEX ssh_key_user_id_index ON ssh_key (user_id);

CREATE TABLE repository_job (
  repository_id INTEGER PRIMARY KEY REFERENCES repository(id) ON DELETE CASCADE,
  requested_by_user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  source_url TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'running', 'succeeded', 'failed')),
  stage_token TEXT NOT NULL DEFAULT '',
  attempt_count INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  source_kind TEXT NOT NULL DEFAULT 'legacy'
  CHECK (source_kind IN ('legacy', 'external', 'local')),
  source_repository_id INTEGER
  REFERENCES repository(id) ON DELETE SET NULL
);

CREATE INDEX repository_job_status_index ON repository_job (status, repository_id);

CREATE TABLE site_settings (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  ssh_public_host TEXT NOT NULL CHECK (ssh_public_host <> ''),
  ssh_public_port INTEGER NOT NULL CHECK (ssh_public_port BETWEEN 1 AND 65535),
  updated_by_user_id INTEGER REFERENCES "user"(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE branch_rule (
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  branch TEXT NOT NULL,
  required_approvals INTEGER NOT NULL DEFAULT 1 CHECK (required_approvals IN (0, 1)),
  allow_self_approval INTEGER NOT NULL DEFAULT 0 CHECK (allow_self_approval IN (0, 1)),
  PRIMARY KEY (repository_id, branch)
);

CREATE TABLE merge_request (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  number INTEGER NOT NULL,
  author_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
  description TEXT NOT NULL DEFAULT '',
  source_branch TEXT NOT NULL,
  target_branch TEXT NOT NULL,
  draft INTEGER NOT NULL DEFAULT 0 CHECK (draft IN (0, 1)),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'merged')),
  current_version INTEGER NOT NULL DEFAULT 0,
  edit_version INTEGER NOT NULL DEFAULT 1,
  issue_id INTEGER REFERENCES issue(id) ON DELETE SET NULL,
  merged_sha TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  check_generation INTEGER NOT NULL DEFAULT 1,
  checks_poll_after INTEGER NOT NULL DEFAULT 0,
  reviews_poll_after INTEGER NOT NULL DEFAULT 0,
  workflow_event TEXT NOT NULL DEFAULT 'opened'
  CHECK (workflow_event IN ('opened', 'reopened', 'synchronize')),
  workflow_event_pending INTEGER NOT NULL DEFAULT 0
  CHECK (workflow_event_pending IN (0, 1)),
  CHECK (source_branch <> target_branch),
  UNIQUE (repository_id, number)
);

CREATE UNIQUE INDEX merge_request_open_branches ON merge_request(repository_id, source_branch, target_branch) WHERE status = 'open';

CREATE TABLE merge_revision (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  merge_request_id INTEGER NOT NULL REFERENCES merge_request(id) ON DELETE CASCADE,
  version INTEGER NOT NULL,
  source_sha TEXT NOT NULL,
  target_sha TEXT NOT NULL,
  base_sha TEXT NOT NULL,
  merge_tree TEXT NOT NULL DEFAULT '',
  block_reason TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  target_branch TEXT NOT NULL DEFAULT '',
  UNIQUE (merge_request_id, version)
);

CREATE TABLE merge_review (
  merge_request_id INTEGER NOT NULL REFERENCES merge_request(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  version INTEGER NOT NULL,
  decision TEXT NOT NULL CHECK (decision IN ('approved', 'changes_requested', 'withdrawn')),
  PRIMARY KEY (merge_request_id, user_id)
);

CREATE TABLE merge_activity (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  merge_request_id INTEGER NOT NULL REFERENCES merge_request(id) ON DELETE CASCADE,
  actor_id INTEGER REFERENCES "user"(id) ON DELETE RESTRICT,
  kind TEXT NOT NULL,
  body TEXT NOT NULL DEFAULT '',
  version INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  discussion_id INTEGER REFERENCES merge_discussion(id) ON DELETE CASCADE
);

CREATE INDEX merge_activity_request ON merge_activity(merge_request_id, id);

CREATE TABLE merge_job (
  merge_request_id INTEGER PRIMARY KEY REFERENCES merge_request(id) ON DELETE CASCADE,
  actor_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  version INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'succeeded', 'failed')),
  result_sha TEXT,
  last_error TEXT,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX merge_job_status ON merge_job(status, merge_request_id);

CREATE TABLE issue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  number INTEGER NOT NULL,
  author_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  assignee_id INTEGER REFERENCES "user"(id) ON DELETE SET NULL,
  title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
  description TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  edit_version INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  closed_at TEXT,
  UNIQUE (repository_id, number)
);

CREATE INDEX issue_repository_status ON issue(repository_id, status, number);

CREATE TABLE issue_activity (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  issue_id INTEGER NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
  actor_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  kind TEXT NOT NULL,
  body TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX issue_activity_issue ON issue_activity(issue_id, id);

CREATE TABLE repository_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  actor_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  kind TEXT NOT NULL,
  detail TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE mail_settings (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  transport TEXT NOT NULL DEFAULT 'file'
    CHECK (transport IN ('file', 'smtp')),
  smtp_host TEXT NOT NULL DEFAULT '',
  smtp_port INTEGER NOT NULL DEFAULT 587
    CHECK (smtp_port BETWEEN 1 AND 65535),
  smtp_security TEXT NOT NULL DEFAULT 'starttls'
    CHECK (smtp_security IN ('plain', 'starttls', 'tls')),
  smtp_auth TEXT NOT NULL DEFAULT 'plain'
    CHECK (smtp_auth IN ('none', 'plain', 'login', 'xoauth2')),
  smtp_username TEXT NOT NULL DEFAULT '',
  smtp_password TEXT NOT NULL DEFAULT '',
  smtp_tls_trust TEXT NOT NULL DEFAULT 'system'
    CHECK (smtp_tls_trust IN ('system', 'insecure', 'custom')),
  smtp_tls_root_cert_file TEXT NOT NULL DEFAULT '',
  smtp_helo_name TEXT NOT NULL DEFAULT 'localhost',
  smtp_from TEXT NOT NULL DEFAULT 'moonhub@localhost',
  updated_by_user_id INTEGER REFERENCES "user"(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE pipeline_run (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  number INTEGER NOT NULL CHECK (number > 0),
  requested_by_user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  workflow_path TEXT NOT NULL,
  workflow_name TEXT NOT NULL,
  source_branch TEXT NOT NULL,
  commit_sha TEXT NOT NULL CHECK (length(commit_sha) IN (40, 64)),
  source_ref TEXT NOT NULL UNIQUE,
  definition_version INTEGER NOT NULL CHECK (definition_version > 0),
  workflow_source TEXT NOT NULL,
  definition_json TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'completed')),
  conclusion TEXT CHECK (conclusion IN ('success', 'failure', 'cancelled', 'timed_out', 'lost')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  cancel_requested INTEGER NOT NULL DEFAULT 0 CHECK (cancel_requested IN (0, 1)),
  trigger_event_id INTEGER REFERENCES repository_ref_event(id),
  merge_check_id INTEGER REFERENCES merge_check(id),
  context_json TEXT,
  CHECK ((status = 'completed' AND conclusion IS NOT NULL) OR (status <> 'completed' AND conclusion IS NULL)),
  UNIQUE (repository_id, number)
);

CREATE INDEX pipeline_run_repository ON pipeline_run(repository_id, number);

CREATE TRIGGER pipeline_run_snapshot_immutable
BEFORE UPDATE OF repository_id, number, requested_by_user_id, workflow_path,
  workflow_name, source_branch, commit_sha, source_ref, definition_version,
  workflow_source, definition_json ON pipeline_run
BEGIN
  SELECT RAISE(ABORT, 'pipeline run snapshots are immutable');
END;

CREATE TABLE pipeline_job (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id INTEGER NOT NULL REFERENCES pipeline_run(id) ON DELETE CASCADE,
  job_key TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  status TEXT NOT NULL CHECK (status IN ('waiting', 'queued', 'leased', 'running', 'completed')),
  conclusion TEXT CHECK (conclusion IN ('success', 'failure', 'cancelled', 'timed_out', 'lost', 'skipped')),
  matrix_group TEXT NOT NULL DEFAULT '',
  max_parallel INTEGER NOT NULL DEFAULT 256 CHECK (max_parallel BETWEEN 1 AND 256),
  matrix_fail_fast INTEGER NOT NULL DEFAULT 0 CHECK (matrix_fail_fast IN (0,1)),
  CHECK ((status = 'completed' AND conclusion IS NOT NULL) OR (status <> 'completed' AND conclusion IS NULL)),
  UNIQUE (run_id, job_key),
  UNIQUE (run_id, ordinal)
);

CREATE INDEX pipeline_job_status ON pipeline_job(status, id);

CREATE TABLE pipeline_job_need (
  run_id INTEGER NOT NULL,
  job_key TEXT NOT NULL,
  needs_job_key TEXT NOT NULL,
  PRIMARY KEY (run_id, job_key, needs_job_key),
  CHECK (job_key <> needs_job_key),
  FOREIGN KEY (run_id, job_key) REFERENCES pipeline_job(run_id, job_key) ON DELETE CASCADE,
  FOREIGN KEY (run_id, needs_job_key) REFERENCES pipeline_job(run_id, job_key) ON DELETE CASCADE
);

CREATE TABLE pipeline_job_attempt (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id INTEGER NOT NULL REFERENCES pipeline_job(id) ON DELETE CASCADE,
  number INTEGER NOT NULL CHECK (number > 0),
  status TEXT NOT NULL CHECK (status IN ('leased', 'running', 'completed')),
  conclusion TEXT CHECK (conclusion IN ('success', 'failure', 'cancelled', 'timed_out', 'lost')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  finished_at TEXT,
  provider_id INTEGER REFERENCES pipeline_provider(id),
  request_id TEXT,
  token_hash TEXT,
  lease_until_ms INTEGER,
  started_at_ms INTEGER,
  deadline_ms INTEGER,
  cancel_at_ms INTEGER,
  log_sequence INTEGER NOT NULL DEFAULT 0,
  log_bytes INTEGER NOT NULL DEFAULT 0,
  result_hash TEXT,
  reported_conclusion TEXT,
  execution_id TEXT,
  worker_id INTEGER REFERENCES pipeline_worker(id),
  CHECK ((status = 'completed' AND conclusion IS NOT NULL AND finished_at IS NOT NULL)
    OR (status <> 'completed' AND conclusion IS NULL AND finished_at IS NULL)),
  UNIQUE (job_id, number)
);

CREATE UNIQUE INDEX pipeline_job_active_attempt ON pipeline_job_attempt(job_id)
  WHERE status <> 'completed';

CREATE TABLE pipeline_provider (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  token_hash TEXT NOT NULL UNIQUE,
  paused INTEGER NOT NULL DEFAULT 0 CHECK (paused IN (0, 1)),
  revoked INTEGER NOT NULL DEFAULT 0 CHECK (revoked IN (0, 1)),
  repository_scope TEXT NOT NULL DEFAULT 'selected'
  CHECK (repository_scope IN ('selected', 'all')),
  last_seen_ms INTEGER,
  mode TEXT NOT NULL DEFAULT '',
  registration_hash TEXT,
  config_schema TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(config_schema)),
  config_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(config_json)),
  config_revision INTEGER NOT NULL DEFAULT 0,
  observed_revision INTEGER NOT NULL DEFAULT 0,
  applied_revision INTEGER NOT NULL DEFAULT 0,
  control_status TEXT NOT NULL DEFAULT 'unregistered',
  controller_id TEXT,
  controller_until_ms INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE pipeline_provider_repository (
  provider_id INTEGER NOT NULL REFERENCES pipeline_provider(id) ON DELETE CASCADE,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  PRIMARY KEY (provider_id, repository_id)
);

CREATE TABLE pipeline_provider_label (
  provider_id INTEGER NOT NULL REFERENCES pipeline_provider(id) ON DELETE CASCADE,
  label TEXT NOT NULL,
  PRIMARY KEY (provider_id, label)
);

CREATE TABLE pipeline_job_label (
  job_id INTEGER NOT NULL REFERENCES pipeline_job(id) ON DELETE CASCADE,
  label TEXT NOT NULL,
  PRIMARY KEY (job_id, label)
);

CREATE UNIQUE INDEX pipeline_attempt_request ON pipeline_job_attempt(provider_id, request_id);

CREATE UNIQUE INDEX pipeline_attempt_token ON pipeline_job_attempt(token_hash);

CREATE INDEX pipeline_attempt_lease ON pipeline_job_attempt(lease_until_ms)
  WHERE status <> 'completed';

CREATE TABLE pipeline_log_chunk (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  sequence INTEGER,
  step_id TEXT NOT NULL,
  stream TEXT NOT NULL CHECK (stream IN ('stdout', 'stderr')),
  content TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  UNIQUE (attempt_id, sequence)
);

CREATE INDEX pipeline_log_cursor ON pipeline_log_chunk(attempt_id, id);

CREATE TABLE pipeline_log_tail (
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  step_id TEXT NOT NULL,
  stream TEXT NOT NULL,
  content TEXT NOT NULL,
  PRIMARY KEY (attempt_id, step_id, stream)
);

CREATE TABLE pipeline_step (
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  step_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'running', 'success', 'failure', 'timed_out', 'cancelled', 'skipped', 'lost')),
  exit_code INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (attempt_id, step_id),
  UNIQUE (attempt_id, ordinal)
);

CREATE TABLE password_reset (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE CHECK (length(token_hash) = 64),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL DEFAULT (datetime('now', '+30 minutes')),
  used_at TEXT
);

CREATE INDEX password_reset_user_created_index ON password_reset (user_id, created_at);

CREATE INDEX email_outbox_password_reset_index ON email_outbox (password_reset_id);

CREATE TABLE repository_ref_event (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  actor_id INTEGER NOT NULL REFERENCES "user"(id),
  source_key TEXT NOT NULL,
  reference TEXT NOT NULL,
  old_sha TEXT NOT NULL,
  new_sha TEXT NOT NULL,
  pin_ref TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL CHECK (state IN ('prepared', 'committed', 'ready', 'processed', 'aborted')),
  last_error TEXT NOT NULL DEFAULT '',
  retry_after INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (repository_id, source_key, reference)
);

CREATE INDEX repository_ref_event_pending ON repository_ref_event(state, id);

CREATE UNIQUE INDEX pipeline_run_push_unique ON pipeline_run(trigger_event_id, workflow_path)
  WHERE trigger_event_id IS NOT NULL;

CREATE TRIGGER pipeline_run_trigger_immutable BEFORE UPDATE OF trigger_event_id ON pipeline_run
BEGIN
  SELECT RAISE(ABORT, 'pipeline trigger identity is immutable');
END;

CREATE TABLE repository_deploy_key (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER REFERENCES repository(id) ON DELETE SET NULL,
  title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
  public_key TEXT NOT NULL UNIQUE CHECK (public_key <> ''),
  fingerprint TEXT NOT NULL UNIQUE CHECK (fingerprint <> ''),
  write_access INTEGER NOT NULL DEFAULT 0 CHECK (write_access IN (0, 1)),
  creator_id INTEGER NOT NULL REFERENCES "user"(id),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_used_at TEXT,
  revoked_at TEXT
);

CREATE INDEX repository_deploy_key_repository ON repository_deploy_key(repository_id);

CREATE TRIGGER repository_deploy_key_delete BEFORE DELETE ON repository
BEGIN
  UPDATE repository_deploy_key SET revoked_at = COALESCE(revoked_at, datetime('now'))
    WHERE repository_id = OLD.id;
END;

CREATE TRIGGER repository_deploy_key_identity_immutable
BEFORE UPDATE OF public_key, fingerprint, creator_id ON repository_deploy_key
BEGIN
  SELECT RAISE(ABORT, 'deploy key identity is immutable');
END;

CREATE TRIGGER repository_deploy_key_binding_immutable
BEFORE UPDATE OF repository_id ON repository_deploy_key
WHEN NEW.repository_id IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'deploy key binding is immutable');
END;

CREATE TRIGGER repository_deploy_key_no_user_collision BEFORE INSERT ON repository_deploy_key
WHEN EXISTS (SELECT 1 FROM ssh_key WHERE fingerprint = NEW.fingerprint OR public_key = NEW.public_key)
BEGIN
  SELECT RAISE(ABORT, 'SSH public key is already registered');
END;

CREATE TRIGGER ssh_key_no_deploy_collision BEFORE INSERT ON ssh_key
WHEN EXISTS (SELECT 1 FROM repository_deploy_key WHERE fingerprint = NEW.fingerprint OR public_key = NEW.public_key)
BEGIN
  SELECT RAISE(ABORT, 'SSH public key is already registered');
END;

CREATE TRIGGER ssh_key_update_no_deploy_collision BEFORE UPDATE OF fingerprint, public_key ON ssh_key
WHEN EXISTS (SELECT 1 FROM repository_deploy_key WHERE fingerprint = NEW.fingerprint OR public_key = NEW.public_key)
BEGIN
  SELECT RAISE(ABORT, 'SSH public key is already registered');
END;

CREATE TABLE branch_required_check (
  repository_id INTEGER NOT NULL,
  branch TEXT NOT NULL,
  workflow_path TEXT NOT NULL,
  PRIMARY KEY (repository_id, branch, workflow_path),
  FOREIGN KEY (repository_id, branch) REFERENCES branch_rule(repository_id, branch) ON DELETE CASCADE
);

CREATE TABLE merge_check (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  merge_request_id INTEGER NOT NULL,
  version INTEGER NOT NULL,
  generation INTEGER NOT NULL,
  workflow_path TEXT NOT NULL,
  requested_by_user_id INTEGER REFERENCES "user"(id),
  state TEXT NOT NULL DEFAULT 'awaiting_approval' CHECK (state IN ('awaiting_approval', 'pending', 'queued', 'running', 'completed', 'error')),
  conclusion TEXT NOT NULL DEFAULT '',
  run_number INTEGER,
  last_error TEXT NOT NULL DEFAULT '',
  retry_after INTEGER NOT NULL DEFAULT 0,
  automatic INTEGER NOT NULL DEFAULT 0
  CHECK (automatic IN (0, 1)),
  FOREIGN KEY (merge_request_id, version) REFERENCES merge_revision(merge_request_id, version) ON DELETE CASCADE,
  UNIQUE (merge_request_id, version, generation, workflow_path)
);

CREATE INDEX merge_check_pending ON merge_check(state, retry_after, id);

CREATE TRIGGER merge_check_context_immutable BEFORE UPDATE OF merge_request_id, version, generation, workflow_path ON merge_check
BEGIN
  SELECT RAISE(ABORT, 'merge check context is immutable');
END;

CREATE INDEX pipeline_run_merge_check ON pipeline_run(merge_check_id);

CREATE TRIGGER pipeline_run_merge_check_immutable BEFORE UPDATE OF merge_check_id ON pipeline_run
BEGIN
  SELECT RAISE(ABORT, 'pipeline merge check identity is immutable');
END;

CREATE TRIGGER pipeline_run_merge_check_result AFTER UPDATE OF status, conclusion ON pipeline_run
WHEN NEW.merge_check_id IS NOT NULL
BEGIN
  UPDATE merge_check SET state = NEW.status, conclusion = COALESCE(NEW.conclusion, '')
  WHERE id = NEW.merge_check_id AND run_number = NEW.number;
END;

CREATE TABLE collaboration_thread (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  issue_id INTEGER UNIQUE REFERENCES issue(id) ON DELETE CASCADE,
  merge_request_id INTEGER UNIQUE REFERENCES merge_request(id) ON DELETE CASCADE,
  CHECK ((issue_id IS NULL) <> (merge_request_id IS NULL))
);

CREATE TRIGGER issue_notification_thread AFTER INSERT ON issue BEGIN
  INSERT INTO collaboration_thread(repository_id, issue_id) VALUES (NEW.repository_id, NEW.id);
END;

CREATE TRIGGER merge_notification_thread AFTER INSERT ON merge_request BEGIN
  INSERT INTO collaboration_thread(repository_id, merge_request_id) VALUES (NEW.repository_id, NEW.id);
END;

CREATE TABLE notification_subscription (
  thread_id INTEGER NOT NULL REFERENCES collaboration_thread(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  subscribed INTEGER NOT NULL DEFAULT 1 CHECK (subscribed IN (0, 1)),
  PRIMARY KEY (thread_id, user_id)
);

CREATE TABLE notification_preferences (
  user_id INTEGER PRIMARY KEY REFERENCES "user"(id) ON DELETE CASCADE,
  email_enabled INTEGER NOT NULL DEFAULT 0 CHECK (email_enabled IN (0, 1))
);

CREATE TABLE merge_review_request (
  merge_request_id INTEGER NOT NULL REFERENCES merge_request(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  requested_by INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  version INTEGER NOT NULL,
  generation INTEGER NOT NULL DEFAULT 1,
  pending INTEGER NOT NULL DEFAULT 1 CHECK (pending IN (0, 1)),
  PRIMARY KEY (merge_request_id, user_id),
  FOREIGN KEY (merge_request_id, version) REFERENCES merge_revision(merge_request_id, version)
);

CREATE INDEX merge_review_request_user ON merge_review_request(user_id, pending, merge_request_id);

CREATE TABLE collaboration_event (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  thread_id INTEGER NOT NULL REFERENCES collaboration_thread(id) ON DELETE CASCADE,
  event_key TEXT NOT NULL UNIQUE,
  actor_id INTEGER REFERENCES "user"(id) ON DELETE SET NULL,
  kind TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 0,
  recipient_id INTEGER REFERENCES "user"(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  discussion_id INTEGER REFERENCES merge_discussion(id) ON DELETE CASCADE,
  comment_id INTEGER REFERENCES merge_activity(id) ON DELETE CASCADE
);

CREATE TABLE collaboration_notification (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id INTEGER NOT NULL REFERENCES collaboration_event(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  read_at TEXT,
  UNIQUE (event_id, user_id)
);

CREATE INDEX collaboration_notification_user ON collaboration_notification(user_id, read_at, id);

CREATE UNIQUE INDEX email_outbox_notification ON email_outbox(notification_id) WHERE notification_id IS NOT NULL;

CREATE VIEW collaboration_access AS
SELECT r.id AS repository_id, u.id AS user_id,
       (u.is_site_admin = 1 OR tm.role IN ('owner', 'admin', 'member')) AS contributor
FROM repository r JOIN "user" u ON u.status = 'active'
LEFT JOIN team_member tm ON tm.team_id = r.team_id AND tm.user_id = u.id
WHERE r.ready = 1 AND (u.is_site_admin = 1 OR tm.role IN ('owner', 'admin', 'member') OR r.visibility = 'public');

CREATE TRIGGER collaboration_event_notifications AFTER INSERT ON collaboration_event BEGIN
  INSERT OR IGNORE INTO collaboration_notification(event_id, user_id)
  SELECT NEW.id, access.user_id FROM collaboration_thread t
  JOIN collaboration_access access ON access.repository_id = t.repository_id
  LEFT JOIN notification_subscription s ON s.thread_id = t.id AND s.user_id = access.user_id
  WHERE t.id = NEW.thread_id AND access.user_id <> COALESCE(NEW.actor_id, 0)
    AND ((NEW.recipient_id IS NOT NULL AND access.user_id = NEW.recipient_id)
      OR (NEW.recipient_id IS NULL AND s.subscribed = 1));
END;

CREATE TRIGGER issue_activity_notifications AFTER INSERT ON issue_activity BEGIN
  INSERT OR IGNORE INTO notification_subscription(thread_id, user_id)
    SELECT id, NEW.actor_id FROM collaboration_thread WHERE issue_id = NEW.issue_id;
  INSERT OR IGNORE INTO notification_subscription(thread_id, user_id)
    SELECT t.id, i.assignee_id FROM collaboration_thread t JOIN issue i ON i.id = t.issue_id
    WHERE i.id = NEW.issue_id AND i.assignee_id IS NOT NULL;
  INSERT INTO collaboration_event(thread_id, event_key, actor_id, kind, recipient_id)
    SELECT t.id, 'issue-activity:' || NEW.id, NEW.actor_id,
      CASE WHEN NEW.kind = 'opened' AND i.assignee_id IS NOT NULL THEN 'assigned' ELSE NEW.kind END,
      CASE WHEN NEW.kind IN ('opened', 'assigned') THEN i.assignee_id ELSE NULL END
    FROM collaboration_thread t JOIN issue i ON i.id = t.issue_id
    WHERE i.id = NEW.issue_id AND NEW.kind IN ('opened', 'assigned', 'comment', 'close', 'reopen');
END;

CREATE TRIGGER merge_review_request_notifications AFTER INSERT ON merge_review_request BEGIN
  INSERT OR IGNORE INTO notification_subscription(thread_id, user_id)
    SELECT t.id, NEW.user_id FROM collaboration_thread t WHERE t.merge_request_id = NEW.merge_request_id
      AND NOT EXISTS (SELECT 1 FROM notification_subscription s WHERE s.thread_id = t.id AND s.user_id = NEW.user_id)
    UNION SELECT t.id, NEW.requested_by FROM collaboration_thread t WHERE t.merge_request_id = NEW.merge_request_id
      AND NOT EXISTS (SELECT 1 FROM notification_subscription s WHERE s.thread_id = t.id AND s.user_id = NEW.requested_by);
  INSERT INTO collaboration_event(thread_id, event_key, actor_id, kind, version, recipient_id)
    SELECT id, 'review-request:' || NEW.merge_request_id || ':' || NEW.user_id || ':' || NEW.generation,
      NEW.requested_by, 'review_requested', NEW.version, NEW.user_id
    FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id;
END;

CREATE TRIGGER merge_review_rerequest_notifications AFTER UPDATE OF generation ON merge_review_request
WHEN NEW.generation <> OLD.generation BEGIN
  INSERT OR IGNORE INTO notification_subscription(thread_id, user_id)
    SELECT t.id, NEW.user_id FROM collaboration_thread t WHERE t.merge_request_id = NEW.merge_request_id
      AND NOT EXISTS (SELECT 1 FROM notification_subscription s WHERE s.thread_id = t.id AND s.user_id = NEW.user_id)
    UNION SELECT t.id, NEW.requested_by FROM collaboration_thread t WHERE t.merge_request_id = NEW.merge_request_id
      AND NOT EXISTS (SELECT 1 FROM notification_subscription s WHERE s.thread_id = t.id AND s.user_id = NEW.requested_by);
  INSERT INTO collaboration_event(thread_id, event_key, actor_id, kind, version, recipient_id)
    SELECT id, 'review-request:' || NEW.merge_request_id || ':' || NEW.user_id || ':' || NEW.generation,
      NEW.requested_by, 'review_requested', NEW.version, NEW.user_id
    FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id;
END;

CREATE TRIGGER merge_check_waiting_notification AFTER INSERT ON merge_check
WHEN NEW.state = 'awaiting_approval' BEGIN
  INSERT OR IGNORE INTO collaboration_event(thread_id, event_key, kind, version)
    SELECT id, 'check:' || NEW.id || ':approval', 'checks_awaiting_approval', NEW.version
    FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id;
END;

CREATE TRIGGER merge_check_failure_notification AFTER UPDATE OF state, conclusion ON merge_check
WHEN NEW.state IN ('completed', 'error') AND (NEW.state <> OLD.state OR NEW.conclusion <> OLD.conclusion)
  AND NEW.conclusion <> 'success' BEGIN
  INSERT OR IGNORE INTO collaboration_event(thread_id, event_key, kind, version)
    SELECT t.id, 'check:' || NEW.id || ':' || COALESCE(NEW.run_number, 0) || ':' || NEW.state || ':' || NEW.conclusion,
      'checks_failed', NEW.version FROM collaboration_thread t JOIN merge_request m ON m.id = t.merge_request_id
    WHERE m.id = NEW.merge_request_id AND m.status = 'open' AND m.draft = 0
      AND m.current_version = NEW.version AND m.check_generation = NEW.generation;
END;

CREATE TABLE access_token (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  token_hash TEXT NOT NULL UNIQUE,
  permission TEXT NOT NULL CHECK (permission IN ('read', 'write', 'execute', 'merge')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  last_used_at TEXT
);

CREATE INDEX access_token_owner ON access_token(user_id, id);

CREATE TABLE merge_execution_approval (
  merge_request_id INTEGER NOT NULL REFERENCES merge_request(id) ON DELETE CASCADE,
  generation INTEGER NOT NULL,
  source_sha TEXT NOT NULL,
  user_id INTEGER NOT NULL REFERENCES "user"(id),
  PRIMARY KEY (merge_request_id, generation, source_sha, user_id)
);

CREATE TRIGGER pipeline_run_context_immutable BEFORE UPDATE OF context_json ON pipeline_run
BEGIN
  SELECT RAISE(ABORT, 'pipeline run context is immutable');
END;

CREATE TABLE merge_discussion (
  id INTEGER PRIMARY KEY REFERENCES merge_activity(id) ON DELETE CASCADE,
  merge_request_id INTEGER NOT NULL REFERENCES merge_request(id) ON DELETE CASCADE,
  author_id INTEGER REFERENCES "user"(id) ON DELETE RESTRICT,
  version INTEGER NOT NULL,
  resolved INTEGER NOT NULL DEFAULT 0 CHECK (resolved IN (0, 1)),
  state_version INTEGER NOT NULL DEFAULT 1 CHECK (state_version > 0),
  state_actor_id INTEGER REFERENCES "user"(id) ON DELETE RESTRICT,
  state_changed_at TEXT,
  anchor TEXT CHECK (anchor IS NULL OR json_valid(anchor)),
  UNIQUE (merge_request_id, id)
);

CREATE INDEX merge_discussion_request ON merge_discussion(merge_request_id, resolved, id);

CREATE INDEX merge_activity_discussion ON merge_activity(discussion_id, id);

CREATE TRIGGER merge_discussion_root AFTER INSERT ON merge_activity
WHEN NEW.discussion_id IS NULL AND (NEW.kind = 'comment'
  OR (NEW.kind IN ('approved', 'changes_requested', 'withdrawn') AND trim(NEW.body) <> '')) BEGIN
  INSERT INTO merge_discussion(id, merge_request_id, author_id, version)
    VALUES (NEW.id, NEW.merge_request_id, NEW.actor_id, NEW.version);
  UPDATE merge_activity SET discussion_id = NEW.id WHERE id = NEW.id;
END;

CREATE TRIGGER merge_discussion_reply_scope BEFORE INSERT ON merge_activity
WHEN NEW.discussion_id IS NOT NULL BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM merge_discussion d WHERE d.id = NEW.discussion_id
      AND d.merge_request_id = NEW.merge_request_id AND d.version = NEW.version
  ) THEN RAISE(ABORT, 'discussion does not belong to this merge request revision') END;
END;

CREATE VIEW collaboration_notification_visible AS
SELECT n.id, n.user_id, n.read_at, e.kind, e.version, e.created_at,
       e.actor_id, e.discussion_id, e.comment_id,
       COALESCE(actor.display_name, 'Moonhub') AS actor,
       t.id AS thread_id, t.repository_id, t.issue_id, t.merge_request_id,
       owner.name_key AS owner, r.name AS repository_name,
       COALESCE(i.number, m.number) AS number, COALESCE(i.title, m.title) AS title
FROM collaboration_notification n JOIN collaboration_event e ON e.id = n.event_id
JOIN collaboration_thread t ON t.id = e.thread_id
JOIN collaboration_access access ON access.repository_id = t.repository_id AND access.user_id = n.user_id
JOIN repository r ON r.id = t.repository_id JOIN team owner ON owner.id = r.team_id
LEFT JOIN "user" actor ON actor.id = e.actor_id
LEFT JOIN issue i ON i.id = t.issue_id LEFT JOIN merge_request m ON m.id = t.merge_request_id;

CREATE TRIGGER collaboration_notification_email AFTER INSERT ON collaboration_notification BEGIN
  INSERT INTO email_outbox(notification_id, to_email, subject, body, template)
  SELECT NEW.id, u.email, 'Moonhub collaboration notification',
    'New activity: ' || v.kind || char(10) || '/' || v.owner || '/' || v.repository_name ||
    CASE WHEN v.issue_id IS NOT NULL THEN '/issues/' ELSE '/merge-requests/' END || v.number ||
    CASE WHEN v.discussion_id IS NOT NULL THEN '?discussion=' || v.discussion_id ||
      CASE WHEN v.comment_id IS NOT NULL THEN '&comment=' || v.comment_id || '#comment-' || v.comment_id
        ELSE '#discussion-' || v.discussion_id END
      ELSE '' END || char(10) ||
    'Open Moonhub to view this item. Manage email delivery in your Inbox settings.', 'collaboration_notification'
  FROM collaboration_notification_visible v JOIN "user" u ON u.id = v.user_id
  JOIN notification_preferences p ON p.user_id = u.id AND p.email_enabled = 1
  WHERE v.id = NEW.id AND u.email IS NOT NULL;
END;

CREATE TRIGGER merge_discussion_notifications AFTER UPDATE OF state_version ON merge_discussion
WHEN NEW.state_version <> OLD.state_version BEGIN
  INSERT INTO merge_activity(merge_request_id, actor_id, kind, version, discussion_id)
    VALUES (NEW.merge_request_id, NEW.state_actor_id,
      CASE WHEN NEW.resolved = 1 THEN 'discussion_resolved' ELSE 'discussion_reopened' END,
      NEW.version, NEW.id);
  INSERT INTO collaboration_event(thread_id, event_key, actor_id, kind, version, discussion_id)
    SELECT id, 'merge-discussion:' || NEW.id || ':' || NEW.state_version, NEW.state_actor_id,
      CASE WHEN NEW.resolved = 1 THEN 'discussion_resolved' ELSE 'discussion_reopened' END,
      NEW.version, NEW.id FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id;
END;

CREATE TRIGGER merge_discussion_anchor_immutable BEFORE UPDATE OF anchor ON merge_discussion
WHEN OLD.anchor IS NOT NULL AND OLD.anchor IS NOT NEW.anchor BEGIN
  SELECT RAISE(ABORT, 'discussion anchors are immutable');
END;

CREATE TABLE "attachment" (
  id TEXT PRIMARY KEY CHECK (length(id) = 64),
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  uploader_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  filename TEXT NOT NULL,
  media_type TEXT NOT NULL CHECK (media_type IN ('image/png', 'image/jpeg', 'image/gif', 'image/webp', 'application/octet-stream')),
  byte_size INTEGER NOT NULL CHECK (byte_size > 0 AND byte_size <= 26214400 AND (media_type = 'application/octet-stream' OR byte_size <= 5242880)),
  sha256 TEXT NOT NULL,
  ready INTEGER NOT NULL DEFAULT 0 CHECK (ready IN (0, 1, 2)),
  claimed INTEGER NOT NULL DEFAULT 0 CHECK (claimed IN (0, 1)),
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX attachment_pending ON attachment(repository_id, uploader_id, created_at);

CREATE TABLE attachment_reference (
  attachment_id TEXT NOT NULL REFERENCES attachment(id) ON DELETE CASCADE,
  merge_request_id INTEGER REFERENCES merge_request(id) ON DELETE CASCADE,
  issue_id INTEGER REFERENCES issue(id) ON DELETE CASCADE,
  merge_activity_id INTEGER REFERENCES merge_activity(id) ON DELETE CASCADE,
  issue_activity_id INTEGER REFERENCES issue_activity(id) ON DELETE CASCADE,
  CHECK ((merge_request_id IS NOT NULL) + (issue_id IS NOT NULL) +
    (merge_activity_id IS NOT NULL) + (issue_activity_id IS NOT NULL) = 1)
);

CREATE UNIQUE INDEX attachment_mr_reference ON attachment_reference(attachment_id, merge_request_id);

CREATE UNIQUE INDEX attachment_issue_reference ON attachment_reference(attachment_id, issue_id);

CREATE UNIQUE INDEX attachment_mr_comment_reference ON attachment_reference(attachment_id, merge_activity_id);

CREATE UNIQUE INDEX attachment_issue_comment_reference ON attachment_reference(attachment_id, issue_activity_id);

CREATE TABLE repository_webhook (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  creator_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  url TEXT NOT NULL,
  secret TEXT NOT NULL,
  events TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1)),
  version INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT(datetime('now'))
);

CREATE INDEX repository_webhook_repository ON repository_webhook(repository_id,id);

CREATE TABLE webhook_event (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  event_key TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT(datetime('now'))
);

CREATE TABLE webhook_delivery (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  webhook_id INTEGER NOT NULL REFERENCES repository_webhook(id) ON DELETE CASCADE,
  event_id INTEGER NOT NULL REFERENCES webhook_event(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','sending','succeeded','failed','cancelled')),
  attempts INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL DEFAULT 5,
  next_attempt_at TEXT NOT NULL DEFAULT(datetime('now')),
  lease TEXT,
  locked_at TEXT,
  response_code INTEGER NOT NULL DEFAULT 0,
  last_error TEXT NOT NULL DEFAULT '',
  completed_at TEXT,
  UNIQUE(webhook_id,event_id)
);

CREATE INDEX webhook_delivery_pending ON webhook_delivery(status,next_attempt_at,id);

CREATE TABLE webhook_attempt (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  delivery_id INTEGER NOT NULL REFERENCES webhook_delivery(id) ON DELETE CASCADE,
  attempt INTEGER NOT NULL,
  response_code INTEGER NOT NULL DEFAULT 0,
  error TEXT NOT NULL DEFAULT '',
  started_at TEXT NOT NULL DEFAULT(datetime('now')),
  completed_at TEXT,
  UNIQUE(delivery_id,attempt)
);

CREATE TABLE webhook_ref_intent (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  actor_id INTEGER REFERENCES "user"(id) ON DELETE RESTRICT,
  deploy_key_id INTEGER REFERENCES repository_deploy_key(id) ON DELETE RESTRICT,
  source_key TEXT NOT NULL,
  reference TEXT NOT NULL,
  old_sha TEXT NOT NULL,
  new_sha TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('prepared','committed','ready','aborted')),
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  CHECK((actor_id IS NULL) <> (deploy_key_id IS NULL)),
  UNIQUE(repository_id,source_key,reference)
);

CREATE INDEX webhook_ref_intent_state ON webhook_ref_intent(state,id);

CREATE TRIGGER webhook_event_deliveries AFTER INSERT ON webhook_event BEGIN
 INSERT INTO webhook_delivery(webhook_id,event_id)
 SELECT h.id,NEW.id FROM repository_webhook h
 WHERE h.repository_id=NEW.repository_id AND h.active=1
 AND instr(',' || h.events || ',', ',' || NEW.kind || ',')>0;
END;

CREATE TRIGGER webhook_issue_activity AFTER INSERT ON issue_activity BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'issue:' || NEW.id,'issue',json_object('schema_version',1,'occurred_at',datetime('now'),'event','issue','action',NEW.kind,
 'repository',json(json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name)),'sender',json(CASE WHEN u.id IS NULL THEN NULL ELSE json_object('id',CAST(u.id AS TEXT),'username',u.name_key) END),'issue',json_object('number',CAST(resource.number AS TEXT),'title',resource.title,'body',resource.description,'state',resource.status,'edit_version',CAST(resource.edit_version AS TEXT)),'activity',json_object('id',CAST(NEW.id AS TEXT),'body',NEW.body))
 FROM issue resource
 JOIN repository r ON r.id=resource.repository_id JOIN team t ON t.id=r.team_id
 LEFT JOIN "user" u ON u.id=NEW.actor_id
 WHERE resource.id=NEW.issue_id
 AND EXISTS(SELECT 1 FROM repository_webhook h WHERE h.repository_id=r.id AND h.active=1);
END;

CREATE TRIGGER webhook_merge_activity AFTER INSERT ON merge_activity BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'mr:' || NEW.id,CASE WHEN NEW.kind IN ('approved','changes_requested','withdrawn') THEN 'review' ELSE 'merge_request' END,json_object('schema_version',1,'occurred_at',datetime('now'),'event',CASE WHEN NEW.kind IN ('approved','changes_requested','withdrawn') THEN 'review' ELSE 'merge_request' END,'action',NEW.kind,
 'repository',json(json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name)),'sender',json(CASE WHEN u.id IS NULL THEN NULL ELSE json_object('id',CAST(u.id AS TEXT),'username',u.name_key) END),'merge_request',json_object('number',CAST(resource.number AS TEXT),'title',resource.title,'body',resource.description,'state',resource.status,'draft',json(CASE resource.draft WHEN 1 THEN 'true' ELSE 'false' END),'version',CAST(resource.current_version AS TEXT),'source_branch',resource.source_branch,'target_branch',resource.target_branch,'merged_sha',resource.merged_sha,'source_sha',(SELECT source_sha FROM merge_revision WHERE merge_request_id=resource.id AND version=NEW.version),'target_sha',(SELECT target_sha FROM merge_revision WHERE merge_request_id=resource.id AND version=NEW.version)),'activity',json_object('id',CAST(NEW.id AS TEXT),'body',NEW.body,'version',CAST(NEW.version AS TEXT),'discussion_id',CAST(COALESCE(NEW.discussion_id,CASE WHEN NEW.kind='comment' THEN NEW.id END) AS TEXT)))
 FROM merge_request resource
 JOIN repository r ON r.id=resource.repository_id JOIN team t ON t.id=r.team_id
 LEFT JOIN "user" u ON u.id=NEW.actor_id
 WHERE resource.id=NEW.merge_request_id
 AND EXISTS(SELECT 1 FROM repository_webhook h WHERE h.repository_id=r.id AND h.active=1);
END;

CREATE TRIGGER webhook_review_request AFTER INSERT ON merge_review_request BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'review:' || NEW.merge_request_id || ':' || NEW.user_id || ':' || NEW.generation,'review',json_object('schema_version',1,'occurred_at',datetime('now'),'event','review','action','review_requested',
 'repository',json(json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name)),'sender',json(CASE WHEN u.id IS NULL THEN NULL ELSE json_object('id',CAST(u.id AS TEXT),'username',u.name_key) END),'merge_request',json_object('number',CAST(resource.number AS TEXT),'version',CAST(NEW.version AS TEXT)),'reviewer_id',CAST(NEW.user_id AS TEXT))
 FROM merge_request resource
 JOIN repository r ON r.id=resource.repository_id JOIN team t ON t.id=r.team_id
 LEFT JOIN "user" u ON u.id=NEW.requested_by
 WHERE resource.id=NEW.merge_request_id
 AND EXISTS(SELECT 1 FROM repository_webhook h WHERE h.repository_id=r.id AND h.active=1);
END;

CREATE TRIGGER webhook_review_rerequest AFTER UPDATE OF generation ON merge_review_request WHEN NEW.generation<>OLD.generation BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'review:' || NEW.merge_request_id || ':' || NEW.user_id || ':' || NEW.generation,'review',json_object('schema_version',1,'occurred_at',datetime('now'),'event','review','action','review_requested',
 'repository',json(json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name)),'sender',json(CASE WHEN u.id IS NULL THEN NULL ELSE json_object('id',CAST(u.id AS TEXT),'username',u.name_key) END),'merge_request',json_object('number',CAST(resource.number AS TEXT),'version',CAST(NEW.version AS TEXT)),'reviewer_id',CAST(NEW.user_id AS TEXT))
 FROM merge_request resource
 JOIN repository r ON r.id=resource.repository_id JOIN team t ON t.id=r.team_id
 LEFT JOIN "user" u ON u.id=NEW.requested_by
 WHERE resource.id=NEW.merge_request_id
 AND EXISTS(SELECT 1 FROM repository_webhook h WHERE h.repository_id=r.id AND h.active=1);
END;

CREATE TRIGGER webhook_pipeline_created AFTER INSERT ON pipeline_run BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'run:' || NEW.id || ':' || NEW.status || ':' || COALESCE(NEW.conclusion,''),'workflow_run',json_object('schema_version',1,'occurred_at',datetime('now'),'event','workflow_run','action',NEW.status,
 'repository',json(json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name)),'sender',json(CASE WHEN u.id IS NULL THEN NULL ELSE json_object('id',CAST(u.id AS TEXT),'username',u.name_key) END),'run',json_object('number',CAST(resource.number AS TEXT),'workflow',resource.workflow_path,'branch',resource.source_branch,'sha',resource.commit_sha,'state',resource.status,'conclusion',resource.conclusion))
 FROM pipeline_run resource
 JOIN repository r ON r.id=resource.repository_id JOIN team t ON t.id=r.team_id
 LEFT JOIN "user" u ON u.id=NEW.requested_by_user_id
 WHERE resource.id=NEW.id
 AND EXISTS(SELECT 1 FROM repository_webhook h WHERE h.repository_id=r.id AND h.active=1);
END;

CREATE TRIGGER webhook_pipeline_state AFTER UPDATE OF status,conclusion ON pipeline_run WHEN NEW.status<>OLD.status OR COALESCE(NEW.conclusion,'')<>COALESCE(OLD.conclusion,'') BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'run:' || NEW.id || ':' || NEW.status || ':' || COALESCE(NEW.conclusion,''),'workflow_run',json_object('schema_version',1,'occurred_at',datetime('now'),'event','workflow_run','action',NEW.status,
 'repository',json(json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name)),'sender',json(CASE WHEN u.id IS NULL THEN NULL ELSE json_object('id',CAST(u.id AS TEXT),'username',u.name_key) END),'run',json_object('number',CAST(resource.number AS TEXT),'workflow',resource.workflow_path,'branch',resource.source_branch,'sha',resource.commit_sha,'state',resource.status,'conclusion',resource.conclusion))
 FROM pipeline_run resource
 JOIN repository r ON r.id=resource.repository_id JOIN team t ON t.id=r.team_id
 LEFT JOIN "user" u ON u.id=NEW.requested_by_user_id
 WHERE resource.id=NEW.id
 AND EXISTS(SELECT 1 FROM repository_webhook h WHERE h.repository_id=r.id AND h.active=1);
END;

CREATE TRIGGER webhook_ref_ready AFTER UPDATE OF state ON webhook_ref_intent
WHEN NEW.state='ready' AND OLD.state<>'ready' BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'push:' || NEW.id,'push',json_object('schema_version',1,'occurred_at',datetime('now'),'event','push',
 'action',CASE WHEN replace(NEW.new_sha,'0','')='' THEN 'deleted' WHEN replace(NEW.old_sha,'0','')='' THEN 'created' ELSE 'updated' END,
 'repository',json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name),
 'sender',json(CASE WHEN NEW.deploy_key_id IS NOT NULL THEN json_object('type','deploy_key','id',CAST(NEW.deploy_key_id AS TEXT)) ELSE json_object('type','user','id',CAST(u.id AS TEXT),'username',u.name_key) END),
 'ref',NEW.reference,'before',NEW.old_sha,'after',NEW.new_sha)
 FROM repository r JOIN team t ON t.id=r.team_id LEFT JOIN "user" u ON u.id=NEW.actor_id
 WHERE r.id=NEW.repository_id;
END;

CREATE TRIGGER webhook_merge_push AFTER INSERT ON merge_activity WHEN NEW.kind='merged' BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'merge-push:' || NEW.id,'push',json_object('schema_version',1,'occurred_at',datetime('now'),'event','push','action','updated',
 'repository',json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name),
 'sender',json_object('id',CAST(u.id AS TEXT),'username',u.name_key),
 'ref','refs/heads/' || m.target_branch,'before',v.target_sha,'after',m.merged_sha)
 FROM merge_request m JOIN merge_revision v ON v.merge_request_id=m.id AND v.version=NEW.version
 JOIN repository r ON r.id=m.repository_id JOIN team t ON t.id=r.team_id JOIN "user" u ON u.id=NEW.actor_id
 WHERE m.id=NEW.merge_request_id AND EXISTS(SELECT 1 FROM repository_webhook h WHERE h.repository_id=r.id AND h.active=1);
END;

CREATE TRIGGER webhook_discussion_anchor AFTER UPDATE OF anchor ON merge_discussion
WHEN OLD.anchor IS NULL AND NEW.anchor IS NOT NULL BEGIN
 UPDATE webhook_event SET payload=json_set(payload,'$.activity.anchor',json(NEW.anchor))
 WHERE event_key='mr:' || NEW.id;
END;

CREATE TABLE pipeline_worker (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  provider_id INTEGER NOT NULL REFERENCES pipeline_provider(id),
  worker_key TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  state TEXT NOT NULL DEFAULT 'starting' CHECK(state IN ('starting','ready','busy','drained','failed')),
  draining INTEGER NOT NULL DEFAULT 0 CHECK(draining IN (0,1)),
  applied_revision INTEGER NOT NULL DEFAULT 0,
  last_seen_ms INTEGER NOT NULL,
  idle_since_ms INTEGER NOT NULL,
  UNIQUE(provider_id,worker_key)
);

CREATE INDEX pipeline_worker_provider ON pipeline_worker(provider_id);

CREATE UNIQUE INDEX pipeline_worker_active_attempt ON pipeline_job_attempt(worker_id) WHERE worker_id IS NOT NULL AND status <> 'completed';

CREATE TABLE repository_mirror (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  creator_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  url TEXT NOT NULL,
  active INTEGER NOT NULL CHECK(active IN (0,1)),
  force_push INTEGER NOT NULL CHECK(force_push IN (0,1)),
  prune INTEGER NOT NULL CHECK(prune IN (0,1)),
  version INTEGER NOT NULL DEFAULT 1,
  generation INTEGER NOT NULL DEFAULT 1,
  synced_generation INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','syncing','succeeded','failed','disabled')),
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT NOT NULL DEFAULT(datetime('now')),
  lease TEXT,
  locked_at TEXT,
  last_error TEXT NOT NULL DEFAULT '',
  last_success_at TEXT,
  host_keys TEXT NOT NULL DEFAULT '',
  UNIQUE(repository_id,url)
);

CREATE INDEX repository_mirror_pending ON repository_mirror(active,status,next_attempt_at);

CREATE TABLE mirror_attempt (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mirror_id INTEGER NOT NULL REFERENCES repository_mirror(id) ON DELETE CASCADE,
  generation INTEGER NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('syncing','succeeded','failed')),
  error TEXT NOT NULL DEFAULT '',
  started_at TEXT NOT NULL DEFAULT(datetime('now')),
  completed_at TEXT
);

CREATE TABLE mirror_ref_intent (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  source_key TEXT NOT NULL,
  reference TEXT NOT NULL,
  old_sha TEXT NOT NULL,
  new_sha TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('prepared','ready','aborted')),
  UNIQUE(repository_id,source_key,reference)
);

CREATE INDEX mirror_ref_intent_state ON mirror_ref_intent(state,repository_id);

CREATE TRIGGER mirror_ref_ready AFTER UPDATE OF state ON mirror_ref_intent
WHEN NEW.state='ready' AND OLD.state='prepared' BEGIN
 UPDATE repository_mirror SET generation=generation+1,
 status=CASE WHEN status='syncing' THEN status ELSE 'pending' END,
 attempts=0,next_attempt_at=datetime('now'),last_error=''
 WHERE repository_id=NEW.repository_id AND active=1;
END;

CREATE TRIGGER mirror_merge_push AFTER INSERT ON merge_activity
WHEN NEW.kind='merged' BEGIN
 UPDATE repository_mirror SET generation=generation+1,
 status=CASE WHEN status='syncing' THEN status ELSE 'pending' END,
 attempts=0,next_attempt_at=datetime('now'),last_error=''
 WHERE repository_id=(SELECT repository_id FROM merge_request WHERE id=NEW.merge_request_id) AND active=1;
END;

CREATE TABLE mirror_ssh_key (
  mirror_id INTEGER PRIMARY KEY REFERENCES repository_mirror(id) ON DELETE CASCADE,
  private_key TEXT NOT NULL,
  public_key TEXT NOT NULL
);

CREATE TABLE mirror_host_check (
  mirror_id INTEGER PRIMARY KEY REFERENCES repository_mirror(id) ON DELETE CASCADE,
  version INTEGER NOT NULL,
  url TEXT NOT NULL,
  challenge TEXT NOT NULL,
  host_keys TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE repository_secret (
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  branch TEXT NOT NULL,
  workflow_path TEXT NOT NULL,
  version INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (repository_id, name)
);

CREATE TABLE pipeline_secret_delivery (
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  step_id TEXT NOT NULL,
  env_name TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (attempt_id, step_id, env_name)
);

CREATE TABLE pipeline_run_schedule (
  run_id INTEGER PRIMARY KEY REFERENCES pipeline_run(id) ON DELETE CASCADE,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  group_key TEXT NOT NULL COLLATE NOCASE,
  admitted INTEGER NOT NULL CHECK (admitted IN (0, 1))
);

CREATE INDEX pipeline_concurrency_group ON pipeline_run_schedule(repository_id, group_key, admitted, run_id);

CREATE INDEX pipeline_matrix_active ON pipeline_job(run_id, matrix_group, status);

CREATE TABLE pipeline_artifact_runtime (
  token_hash TEXT PRIMARY KEY,
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  execution_id TEXT NOT NULL,
  origin TEXT NOT NULL,
  expires_ms INTEGER NOT NULL
);

CREATE INDEX pipeline_artifact_runtime_attempt ON pipeline_artifact_runtime(attempt_id);

CREATE TABLE pipeline_artifact (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  run_id INTEGER NOT NULL REFERENCES pipeline_run(id) ON DELETE CASCADE,
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  storage_key TEXT NOT NULL UNIQUE,
  state TEXT NOT NULL CHECK(state IN ('pending','assembling','uploaded','ready','deleted')),
  size INTEGER NOT NULL DEFAULT 0,
  digest TEXT NOT NULL DEFAULT '',
  created_ms INTEGER NOT NULL,
  expires_ms INTEGER NOT NULL,
  generation TEXT NOT NULL DEFAULT '',
  block_order TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL DEFAULT 'artifact' CHECK(kind IN ('artifact','cache'))
);

CREATE INDEX pipeline_artifact_cleanup ON pipeline_artifact(state,expires_ms,id);

CREATE TABLE pipeline_artifact_block (
  artifact_id INTEGER NOT NULL REFERENCES pipeline_artifact(id) ON DELETE CASCADE,
  block_id TEXT NOT NULL,
  file_key TEXT NOT NULL,
  size INTEGER NOT NULL,
  digest TEXT NOT NULL,
  PRIMARY KEY(artifact_id,block_id)
);

CREATE TABLE pipeline_artifact_capability (
  token_hash TEXT PRIMARY KEY,
  runtime_hash TEXT NOT NULL REFERENCES pipeline_artifact_runtime(token_hash) ON DELETE CASCADE,
  artifact_id INTEGER NOT NULL REFERENCES pipeline_artifact(id) ON DELETE CASCADE,
  operation TEXT NOT NULL CHECK(operation IN ('write','read')),
  expires_ms INTEGER NOT NULL
);

CREATE INDEX pipeline_artifact_runtime_expiry ON pipeline_artifact_runtime(expires_ms);

CREATE INDEX pipeline_artifact_run ON pipeline_artifact(run_id,id);

CREATE INDEX pipeline_artifact_capability_runtime ON pipeline_artifact_capability(runtime_hash);

CREATE INDEX pipeline_artifact_capability_artifact ON pipeline_artifact_capability(artifact_id);

CREATE INDEX pipeline_artifact_capability_expiry ON pipeline_artifact_capability(expires_ms);

CREATE UNIQUE INDEX pipeline_artifact_name ON pipeline_artifact(run_id,name) WHERE state <> 'deleted' AND kind='artifact';

CREATE TABLE pipeline_cache_scope (
  run_id INTEGER PRIMARY KEY REFERENCES pipeline_run(id) ON DELETE CASCADE,
  scope TEXT NOT NULL,
  base_scope TEXT NOT NULL,
  default_scope TEXT NOT NULL
);

CREATE TRIGGER pipeline_cache_scope_immutable BEFORE UPDATE ON pipeline_cache_scope BEGIN SELECT RAISE(ABORT, 'pipeline cache scopes are immutable'); END;

CREATE TABLE pipeline_cache (
  artifact_id INTEGER PRIMARY KEY REFERENCES pipeline_artifact(id) ON DELETE CASCADE,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  scope TEXT NOT NULL,
  key TEXT NOT NULL,
  version TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','ready','deleted')),
  created_ms INTEGER NOT NULL,
  last_access_ms INTEGER NOT NULL
);

CREATE UNIQUE INDEX pipeline_cache_key ON pipeline_cache(repository_id,scope,key,version) WHERE state <> 'deleted';

CREATE INDEX pipeline_cache_lookup ON pipeline_cache(repository_id,scope,version,state,created_ms);

CREATE INDEX pipeline_cache_eviction ON pipeline_cache(repository_id,state,last_access_ms);

CREATE TRIGGER merge_activity_notifications AFTER INSERT ON merge_activity BEGIN
  INSERT OR IGNORE INTO notification_subscription(thread_id, user_id)
    SELECT id, NEW.actor_id FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id AND NEW.actor_id IS NOT NULL;
  INSERT INTO collaboration_event(thread_id, event_key, actor_id, kind, version, discussion_id, comment_id)
    SELECT id, 'merge-activity:' || NEW.id, NEW.actor_id, NEW.kind, NEW.version,
      CASE WHEN NEW.discussion_id IS NOT NULL THEN NEW.discussion_id
        WHEN NEW.kind = 'comment' OR (NEW.kind IN ('approved', 'changes_requested', 'withdrawn') AND trim(NEW.body) <> '') THEN NEW.id
        ELSE NULL END,
      CASE WHEN NEW.discussion_id IS NOT NULL OR NEW.kind = 'comment'
        OR (NEW.kind IN ('approved', 'changes_requested', 'withdrawn') AND trim(NEW.body) <> '') THEN NEW.id ELSE NULL END
    FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id
      AND NEW.kind IN ('opened', 'comment', 'approved', 'changes_requested', 'withdrawn', 'merged', 'close', 'reopen', 'ready', 'updated', 'retargeted');
  UPDATE merge_review_request SET pending = 0
    WHERE merge_request_id = NEW.merge_request_id AND user_id = NEW.actor_id AND version = NEW.version
      AND NEW.kind IN ('approved', 'changes_requested');
  UPDATE merge_review_request SET version = NEW.version, pending = 1
    WHERE merge_request_id = NEW.merge_request_id AND NEW.kind IN ('updated', 'ready', 'reopen', 'retargeted');
  UPDATE merge_review_request SET pending = 1 WHERE merge_request_id = NEW.merge_request_id AND user_id = NEW.actor_id AND NEW.kind = 'withdrawn';
END;

CREATE TABLE pipeline_job_output (
  id INTEGER PRIMARY KEY,
  job_id INTEGER NOT NULL UNIQUE REFERENCES pipeline_job(id) ON DELETE CASCADE,
  attempt_id INTEGER NOT NULL UNIQUE REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  outputs_json TEXT NOT NULL
);

CREATE TABLE repository_variable (
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  version INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (repository_id, name)
);

CREATE TABLE pipeline_oidc_runtime (
  token_hash TEXT PRIMARY KEY,
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  execution_id TEXT NOT NULL,
  expires_ms INTEGER NOT NULL,
  requests INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX pipeline_oidc_runtime_attempt ON pipeline_oidc_runtime(attempt_id);

CREATE TABLE user_preferences (
  user_id INTEGER PRIMARY KEY REFERENCES "user" (id) ON DELETE CASCADE,
  time_zone TEXT,
  CHECK (time_zone IS NULL OR (length(time_zone) BETWEEN 1 AND 100))
);
