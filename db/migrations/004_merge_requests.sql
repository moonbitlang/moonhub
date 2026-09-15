CREATE TABLE branch_rule (
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  branch TEXT NOT NULL,
  required_approvals INTEGER NOT NULL DEFAULT 1 CHECK (required_approvals IN (0, 1)),
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
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
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
