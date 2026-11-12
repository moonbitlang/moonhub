///|
pub suberror Conflict {
  Conflict(String)
}

///|
pub struct Access {
  repo : @domain.RepoId
  actor : @domain.CurrentUser?
  recheck : (Bool) -> Unit raise
}

///|
pub fn access(
  repo : @domain.RepoId,
  actor : @domain.CurrentUser?,
  recheck~ : (Bool) -> Unit raise = _ => (),
) -> Access {
  { repo, actor, recheck, }
}

///|
pub struct Service {
  pool : @database.Database
  root : String
  storage : @storage.Config?
  clock : () -> Int64
}

///|
pub fn Service::new(
  pool : @database.Database,
  root : String,
  storage? : @storage.Config,
  clock~ : () -> Int64 = () => @env.now().reinterpret_as_int64(),
) -> Service {
  { pool, root, storage, clock, }
}

///|
pub(all) struct Asset {
  id : Int64
  release_id : Int64
  name : String
  label : String
  media_type : String
  size : Int64
  digest : String
  created_at : String
  priv location : String
  priv storage_key : String
}

///|
pub(all) struct Release {
  id : Int64
  tag : String
  commit_sha : String
  title : String
  body : String
  draft : Bool
  prerelease : Bool
  revision : Int64
  author : String
  created_at : String
  published_at : String?
  assets : Array[Asset]
}

///|
fn Service::authorize(
  self : Service,
  access : Access,
  write : Bool,
) -> Int64 raise {
  (access.recheck)(write)
  if write {
    guard access.actor is Some(actor) else {
      raise @domain.Unauthorized(message="release writer required")
    }
    @repository.authorize_repository(self.pool, actor, access.repo, Write)
  } else {
    guard @repository.can_read_repository(self.pool, access.actor, access.repo) else {
      raise @domain.NotFound(message="release not found or access denied")
    }
  }
  self.pool.with_client(c => {
    c
    .query_one(
      "SELECT r.id FROM repository r JOIN team t ON t.id=r.team_id WHERE t.name_key=? AND r.name=? AND r.ready=1",
      params=[access.repo.owner, access.repo.name],
    )
    .get_name("id")
  })
}

///|
fn Service::writer(self : Service, access : Access) -> Bool {
  ignore(self.authorize(access, true)) catch {
    _ => return false
  }
  true
}

///|
fn asset(row : @database.DbRow) -> Asset raise {
  {
    id: row.get_name("id"),
    release_id: row.get_name("release_id"),
    name: row.get_name("name"),
    label: row.get_name("label"),
    media_type: row.get_name("media_type"),
    size: row.get_name("size"),
    digest: row.get_name("digest"),
    created_at: row.get_name("created_at"),
    location: row.get_name("location"),
    storage_key: row.get_name("storage_key"),
  }
}

///|
fn decode_release(
  c : @database.DbClient,
  row : @database.DbRow,
) -> Release raise {
  let id : Int64 = row.get_name("id")
  {
    id,
    tag: row.get_name("tag"),
    commit_sha: row.get_name("commit_sha"),
    title: row.get_name("title"),
    body: row.get_name("body"),
    draft: row.get_name("draft"),
    prerelease: row.get_name("prerelease"),
    revision: row.get_name("revision"),
    author: row.get_name("author"),
    created_at: row.get_name("created_at"),
    published_at: row.get_name("published_at"),
    assets: c
    .query_all(
      "SELECT * FROM release_asset WHERE release_id=? AND state='ready' ORDER BY id",
      params=[id],
    )
    .map(asset),
  }
}

///|
let release_select = "SELECT r.*,u.name_key author FROM repository_release r JOIN user u ON u.id=r.author_id"

///|
pub fn Service::list(
  self : Service,
  access : Access,
  page~ : Int32 = 1,
  per_page~ : Int32 = 30,
) -> Array[Release] raise {
  let repo = self.authorize(access, false)
  guard page >= 1 && page <= 100000 && per_page >= 1 && per_page <= 100 else {
    raise @domain.BadRequest(message="invalid release pagination")
  }
  let drafts = self.writer(access)
  self.pool.with_client(c => {
    c
    .query_all(
      release_select +
      " WHERE r.repository_id=? AND r.deleted=0 AND (r.draft=0 OR ?=1) ORDER BY r.id DESC LIMIT ? OFFSET ?",
      params=[
        repo,
        drafts,
        per_page.to_int64(),
        ((page - 1) * per_page).to_int64(),
      ],
    )
    .map(r => decode_release(c, r))
  })
}

///|
pub fn Service::get(
  self : Service,
  access : Access,
  id : Int64,
) -> Release raise {
  let repo = self.authorize(access, false)
  let drafts = self.writer(access)
  self.pool.with_client(c => {
    let row = c.query_opt(
      release_select +
      " WHERE r.repository_id=? AND r.id=? AND r.deleted=0 AND (r.draft=0 OR ?=1)",
      params=[repo, id, drafts],
    )
    guard row is Some(row) else {
      raise @domain.NotFound(message="release not found")
    }
    decode_release(c, row)
  })
}

///|
pub fn Service::by_tag(
  self : Service,
  access : Access,
  tag : String,
) -> Release raise {
  let repo = self.authorize(access, false)
  let id = self.pool.with_client(c => {
    let r = c.query_opt(
      "SELECT id FROM repository_release WHERE repository_id=? AND tag=? AND deleted=0",
      params=[repo, tag],
    )
    guard r is Some(r) else {
      raise @domain.NotFound(message="release not found")
    }
    (r.get_name("id") : Int64)
  })
  self.get(access, id)
}

///|
pub fn Service::latest(self : Service, access : Access) -> Release raise {
  let repo = self.authorize(access, false)
  let id = self.pool.with_client(c => {
    let row = c.query_opt(
      "SELECT r.id FROM repository_release r LEFT JOIN repository_release_latest l ON l.release_id=r.id AND l.repository_id=r.repository_id WHERE r.repository_id=? AND r.deleted=0 AND r.draft=0 AND r.prerelease=0 ORDER BY (l.release_id IS NOT NULL) DESC,r.published_at DESC,r.id DESC LIMIT 1",
      params=[repo],
    )
    guard row is Some(row) else {
      raise @domain.NotFound(message="no published release")
    }
    (row.get_name("id") : Int64)
  })
  self.get(access, id)
}

///|
fn validate_text(value : String, maximum : Int32) -> Unit raise {
  guard @utf8.encode(value).length() <= maximum && !value.contains("\u0000") else {
    raise @domain.BadRequest(message="invalid release text")
  }
}

///|
async fn release_commit(
  root : String,
  repo : @domain.RepoId,
  tag : String,
  target : String,
) -> String {
  guard !tag.is_empty() &&
    tag.length() <= 200 &&
    !tag.contains("/") &&
    !tag.has_prefix("-") &&
    tag
    .iter()
    .all(c => {
      c.is_ascii_alphabetic() ||
      c.is_ascii_digit() ||
      "._-".contains(c.to_string())
    }) else {
    raise @domain.BadRequest(message="invalid release tag")
  }
  let dir = repo.git_dir(root)
  guard @gitops.merge_git_command(dir, ["check-ref-format", "refs/tags/" + tag]).0 ==
    0 else {
    raise @domain.BadRequest(message="invalid release tag")
  }
  // Full commit identity is resolved once; branch movement never retargets a release.
  if @gitops.valid_commit_sha(target) {
    ignore(@gitops.commit_comparison(dir, target))
    target
  } else {
    @gitops.branch_sha(
      dir,
      if target == "HEAD" {
        @gitops.default_ref(dir)
      } else {
        target
      },
    )
  }
}

///|
pub async fn Service::create(
  self : Service,
  access : Access,
  tag : String,
  target : String,
  title : String,
  body : String,
  draft~ : Bool = true,
  prerelease~ : Bool = false,
  latest~ : Bool = true,
) -> Release {
  ignore(self.authorize(access, true))
  validate_text(title, 1024)
  validate_text(body, 65536)
  let actor = access.actor.unwrap()
  let id = @repository.with_repository_write(
    self.pool,
    self.root,
    actor,
    access.repo,
    (scope, dir) => {
      let sha = release_commit(self.root, access.repo, tag, target)
      let pin = "refs/moonhub/releases/" + @identity.random_hex(16)
      ignore(@gitops.merge_git(dir, ["update-ref", pin, sha]))
      let committed = Ref(false)
      defer (if !committed.val {
        @async.protect_from_cancel(() => {
          ignore(@gitops.merge_git(dir, ["update-ref", "-d", pin, sha]))
        }) catch {
          _ => ()
        }
      })
      ignore(self.authorize(access, true))
      let id = self.pool.with_client(c => {
        c.with_transaction(
          tx => {
            guard tx.query_opt(
                "SELECT id FROM repository_release WHERE repository_id=? AND tag=? AND deleted=0",
                params=[scope.id, tag],
              )
              is None else {
              raise Conflict("release tag already exists")
            }
            ignore(
              tx.execute(
                "INSERT INTO repository_release(repository_id,tag,commit_sha,source_ref,title,body,prerelease,author_id) VALUES(?,?,?,?,?,?,?,?)",
                params=[
                  scope.id,
                  tag,
                  sha,
                  pin,
                  title,
                  body,
                  prerelease,
                  actor.id,
                ],
              ),
            )
            (
              tx.query_one("SELECT last_insert_rowid() id").get_name("id") :
              Int64)
          },
          immediate=true,
        )
      })
      committed.val = true
      id
    },
  )
  if !draft {
    self.publish(access, id, latest~)
  } else {
    self.get(access, id)
  }
}

///|
pub async fn Service::edit(
  self : Service,
  access : Access,
  id : Int64,
  target? : String,
  title? : String,
  body? : String,
  draft? : Bool,
  prerelease? : Bool,
  latest~ : Bool = false,
) -> Release {
  ignore(self.authorize(access, true))
  @repository.with_repository_write(
    self.pool,
    self.root,
    access.actor.unwrap(),
    access.repo,
    (_, dir) => {
      let before = self.get(access, id)
      let next_title = title.unwrap_or(before.title)
      let next_body = body.unwrap_or(before.body)
      validate_text(next_title, 1024)
      validate_text(next_body, 65536)
      let sha = match target {
        Some(target) =>
          release_commit(self.root, access.repo, before.tag, target)
        None => before.commit_sha
      }
      guard before.draft ||
        (
          sha == before.commit_sha &&
          next_title == before.title &&
          next_body == before.body &&
          !draft.unwrap_or(false) &&
          prerelease.unwrap_or(before.prerelease) == before.prerelease
        ) else {
        raise Conflict("published releases are immutable")
      }
      let pin = if sha == before.commit_sha {
        self.pool.with_client(c => {
          c
          .query_one("SELECT source_ref FROM repository_release WHERE id=?", params=[
            id,
          ])
          .get_name("source_ref")
        })
      } else {
        let reference = "refs/moonhub/releases/" + @identity.random_hex(16)
        ignore(@gitops.merge_git(dir, ["update-ref", reference, sha]))
        reference
      }
      ignore(self.authorize(access, true))
      self.pool.with_client(c => {
        c.with_transaction(
          tx => {
            guard tx.execute(
                "UPDATE repository_release SET title=?,body=?,commit_sha=?,source_ref=?,prerelease=?,revision=revision+1 WHERE id=? AND revision=? AND deleted=0",
                params=[
                  next_title,
                  next_body,
                  sha,
                  pin,
                  prerelease.unwrap_or(before.prerelease),
                  id,
                  before.revision,
                ],
              ) ==
              1 else {
              raise Conflict("release changed; reload and retry")
            }
          },
          immediate=true,
        )
      })
    },
  )
  if draft == Some(false) || latest {
    self.publish(access, id, latest~)
  } else {
    self.get(access, id)
  }
}

///|
pub async fn Service::publish(
  self : Service,
  access : Access,
  id : Int64,
  latest~ : Bool = true,
) -> Release {
  ignore(self.authorize(access, true))
  @repository.with_repository_write(
    self.pool,
    self.root,
    access.actor.unwrap(),
    access.repo,
    (_, dir) => {
      let before = self.get(access, id)
      ignore(self.authorize(access, true))
      self.pool.with_client(c => {
        guard c
          .query_one(
            "SELECT count(*) n FROM release_asset WHERE release_id=? AND state<>'deleted' AND (state<>'ready' OR commit_sha<>?)",
            params=[id, before.commit_sha],
          )
          .get_name("n") ==
          0L else {
          raise Conflict(
            "release assets are unfinished or target a different commit",
          )
        }
      })
      let reference = "refs/tags/" + before.tag
      let (code, existing) = @gitops.merge_git_command(dir, [
        "rev-parse",
        "--verify",
        reference + "^{commit}",
      ])
      if code == 0 {
        guard existing.trim() == before.commit_sha else {
          raise Conflict("release tag points to a different commit")
        }
      } else {
        let txid = @identity.random_hex(16)
        let updates = "0".repeat(before.commit_sha.length()) +
          " " +
          before.commit_sha +
          " " +
          reference +
          "\n"
        @repository.record_received_transaction(
          self.pool,
          access.actor.unwrap(),
          access.repo,
          txid,
          "prepared",
          updates,
        )
        ignore(
          @gitops.merge_git(dir, [
            "update-ref",
            reference,
            before.commit_sha,
            "0".repeat(before.commit_sha.length()),
          ]),
        )
        @repository.record_received_transaction(
          self.pool,
          access.actor.unwrap(),
          access.repo,
          txid,
          "committed",
          updates,
        )
      }
      ignore(self.authorize(access, true))
      self.pool.with_client(c => {
        c.with_transaction(
          tx => {
            guard (
                tx
                .query_one(
                  "SELECT count(*) n FROM release_asset WHERE release_id=? AND state<>'deleted' AND (state<>'ready' OR commit_sha<>?)",
                  params=[id, before.commit_sha],
                )
                .get_name("n") : Int64) ==
              0L else {
              raise Conflict("release assets changed during publication")
            }
            guard tx.execute(
                "UPDATE repository_release SET draft=0,published_at=COALESCE(published_at,strftime('%Y-%m-%dT%H:%M:%SZ','now')),revision=revision+1 WHERE id=? AND revision=? AND deleted=0",
                params=[id, before.revision],
              ) ==
              1 else {
              raise Conflict("release changed before publication")
            }
            if latest && !before.prerelease {
              ignore(
                tx.execute(
                  "INSERT INTO repository_release_latest(repository_id,release_id) SELECT repository_id,id FROM repository_release WHERE id=? ON CONFLICT(repository_id) DO UPDATE SET release_id=excluded.release_id",
                  params=[id],
                ),
              )
            }
          },
          immediate=true,
        )
      })
    },
  )
  self.get(access, id)
}

///|
pub fn Service::delete(
  self : Service,
  access : Access,
  id : Int64,
) -> Unit raise {
  ignore(self.authorize(access, true))
  let r = self.get(access, id)
  guard r.draft else { raise Conflict("published releases are immutable") }
  self.pool.with_client(c => {
    c.with_transaction(
      tx => {
        guard tx.execute(
            "UPDATE repository_release SET deleted=1,revision=revision+1 WHERE id=? AND draft=1 AND revision=?",
            params=[id, r.revision],
          ) ==
          1 else {
          raise Conflict("release changed")
        }
        ignore(
          tx.execute(
            "UPDATE release_asset SET state='deleted',expires_ms=? WHERE release_id=?",
            params=[(self.clock)() + 600000L, id],
          ),
        )
      },
      immediate=true,
    )
  })
}
