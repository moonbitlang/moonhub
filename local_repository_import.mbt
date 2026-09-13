///|
struct ResolvedRepoImport {
  submitted_url : String
  transport : SshImportSource
  local_id : Int64?
}

///|
fn readable_source_repository(
  pool : Database,
  actor : CurrentUser,
  id : Int64,
) -> RepoId raise {
  let repo = pool.with_client(client => {
    let row = client.query_opt(
      "SELECT t.name_key AS owner, r.name FROM repository AS r JOIN team AS t ON t.id = r.team_id WHERE r.id = ? AND r.ready = 1",
      params=[id],
    )
    guard row is Some(row) else {
      raise NotFound(message="source repository not found or access denied")
    }
    { owner: row.get_name("owner"), name: row.get_name("name"), }
  })
  authorize_repository(pool, actor, repo, Read)
  repo
}

///|
fn resolve_repository_import_source(
  pool : Database,
  actor : CurrentUser,
  source_url : String,
  addresses : SshAddressConfig,
) -> ResolvedRepoImport raise {
  let source = parse_ssh_import_source(source_url)
  let endpoint : SshEndpoint = { host: source.host, port: source.port, }
  let is_local = effective_ssh_endpoint(pool, addresses) == Some(endpoint) ||
    addresses.internal == Some(endpoint)
  if !is_local {
    return { submitted_url: source.url, transport: source, local_id: None, }
  }
  guard source.user == "git" else {
    raise BadRequest(message="this instance uses the git SSH username")
  }
  let repo = parse_transport_repo(source.path)
  authorize_repository(pool, actor, repo, Read)
  let id : Int64 = pool.with_client(client => {
    let row = client.query_opt(
      "SELECT r.id FROM repository AS r JOIN team AS t ON t.id = r.team_id WHERE t.name_key = ? AND r.name = ? AND r.ready = 1",
      params=[repo.owner, repo.name],
    )
    guard row is Some(row) else {
      raise NotFound(message="source repository not found or access denied")
    }
    row.get_name("id")
  })
  guard addresses.internal is Some(internal) else {
    raise BadRequest(message="internal SSH connection is not configured")
  }
  {
    submitted_url: source.url,
    transport: parse_ssh_import_source(internal.clone_url(repo)),
    local_id: Some(id),
  }
}

///|
fn pin_legacy_repository_source(
  pool : Database,
  actor : CurrentUser,
  job : RepositoryJob,
  addresses : SshAddressConfig,
) -> RepositoryJob raise {
  if job.source_kind != "legacy" || job.source_url.is_empty() {
    return job
  }
  let source = resolve_repository_import_source(
    pool,
    actor,
    job.source_url,
    addresses,
  )
  pool.with_client(client => {
    match source.local_id {
      Some(id) => {
        let _ = client.execute(
          "UPDATE repository_job SET source_kind = 'local', source_repository_id = ? WHERE repository_id = ?",
          params=[id, job.id],
        )
      }
      None => {
        let _ = client.execute(
          "UPDATE repository_job SET source_kind = 'external' WHERE repository_id = ?",
          params=[job.id],
        )
      }
    }
  })
  {
    ..job,
    source_kind: if source.local_id is Some(_) {
      "local"
    } else {
      "external"
    },
    source_repository_id: source.local_id,
  }
}

///|
fn repository_job_source(
  pool : Database,
  actor : CurrentUser,
  job : RepositoryJob,
  addresses : SshAddressConfig,
) -> SshImportSource? raise {
  if job.source_url.is_empty() {
    return None
  }
  if job.source_kind == "local" {
    guard job.source_repository_id is Some(id) else {
      raise NotFound(message="source repository no longer exists")
    }
    let repo = readable_source_repository(pool, actor, id)
    guard addresses.internal is Some(internal) else {
      raise BadRequest(message="internal SSH connection is not configured")
    }
    Some(parse_ssh_import_source(internal.clone_url(repo)))
  } else {
    Some(parse_ssh_import_source(job.source_url))
  }
}
