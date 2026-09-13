///|
fn management_command() -> @argparse.Command {
  @argparse.Command(
    "moonhub",
    subcommand_required=true,
    options=[
      OptionArg(
        "db",
        long="db",
        env="DB_PATH",
        default_values=["moonhub.db"],
        global=true,
      ),
      OptionArg(
        "root",
        long="root",
        env="MOONHUB_REPO_ROOT",
        default_values=["repos"],
        global=true,
      ),
    ],
    subcommands=[
      @argparse.Command("ssh-authorized-key", hidden=true, positionals=[
        PositionArg("system-user"),
        PositionArg("type"),
        PositionArg("key"),
      ]),
      @argparse.Command("ssh-serve", hidden=true, positionals=[
        PositionArg("id"),
      ]),
      @argparse.Command(
        "ssh-key-add",
        about="Bind an Ed25519 public key to an active user.",
        positionals=[PositionArg("user")],
        options=[
          OptionArg("title", long="title", default_values=["SSH key"]),
          OptionArg(
            "file",
            long="file",
            about="Public key file; reads stdin when omitted.",
          ),
        ],
      ),
      @argparse.Command("ssh-key-list", about="List registered SSH keys.", options=[
        OptionArg("user", long="user"),
      ]),
      @argparse.Command(
        "ssh-key-revoke",
        about="Revoke an SSH key immediately for new operations.",
        positionals=[PositionArg("id")],
      ),
      @argparse.Command(
        "repo-create",
        about="Create a registered bare repository, or register an existing one.",
        positionals=[PositionArg("repository")],
        flags=[
          FlagArg(
            "import",
            long="import",
            about="Register an existing bare repository without changing its Git data.",
          ),
        ],
        options=[
          OptionArg("visibility", long="visibility", default_values=["private"]),
        ],
      ),
    ],
  )
}

///|
fn cli_value(matches : @argparse.Matches, name : String) -> String raise {
  guard single_value(matches, name) is Some(value) else {
    raise BadRequest(message="missing \{name}")
  }
  value
}

///|
fn cli_key_id(matches : @argparse.Matches) -> Int64 raise {
  let value = cli_value(matches, "id")
  let id = @string.parse_int64(value) catch {
    _ => raise BadRequest(message="invalid SSH key id")
  }
  guard id > 0L else { raise BadRequest(message="invalid SSH key id") }
  id
}

///|
async fn create_managed_repository(
  pool : Database,
  root : String,
  repo : RepoId,
  visibility : String,
  import_existing : Bool,
) -> Unit {
  guard visibility == "public" || visibility == "private" else {
    raise BadRequest(message="visibility must be public or private")
  }
  guard get_team_by_name_key(pool, repo.owner) is Some(team) else {
    raise NotFound(
      message="repository owner must be an existing personal or organization team",
    )
  }
  let exists = pool.with_client(client => {
    client.query_opt(
      "SELECT id FROM repository WHERE team_id = ? AND name = ?",
      params=[team.id, repo.name],
    )
  })
  guard exists is None else {
    raise BadRequest(message="repository is already registered")
  }
  let root = trim_trailing_slash(@fs.realpath(root))
  let git_dir = repo.git_dir(root)
  if import_existing {
    let _ = resolve_repository_dir(root, repo)
  } else {
    guard !@fs.exists(git_dir) else {
      raise BadRequest(
        message="repository directory already exists; use --import to register it",
      )
    }
    let owner_dir = "\{root}/\{repo.owner}"
    if !@fs.exists(owner_dir) {
      @fs.mkdir(owner_dir, permission=0o750)
    }
    guard @fs.realpath(owner_dir) == owner_dir else {
      raise BadRequest(
        message="repository owner directory must not be a symbolic link",
      )
    }
    let (code, output) = @process.collect_output_merged("git", [
      "init", "--bare", "--initial-branch=main", git_dir,
    ])
    guard code == 0 else {
      raise BadRequest(message="git init failed: \{output.text()}")
    }
  }
  let bare = run_git(git_dir, ["rev-parse", "--is-bare-repository"])
  guard bare.trim() == "true" else {
    raise BadRequest(message="only bare repositories can be registered")
  }
  pool.with_client(client => {
    let _ = client.execute(
      "INSERT INTO repository (team_id, name, visibility) VALUES (?, ?, ?)",
      params=[team.id, repo.name, visibility],
    )
  })
}

///|
async fn run_management_cli(args : ArrayView[String]) -> Int {
  let matches = management_command().parse(argv=args, env=@env.get_env_vars())
  guard matches.subcommand is Some((command, options)) else { return 1 }
  let db_path = cli_value(matches, "db")
  guard @fs.exists(db_path) else {
    raise NotFound(message="database not found; start the web service first")
  }
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: db_path, }, group)
    defer pool.close()
    let version : Int64 = pool.with_client(client => {
      guard client.query_opt("PRAGMA user_version") is Some(row) else {
        raise BadRequest(message="cannot read database schema version")
      }
      row.get_name("user_version")
    })
    guard version == database_schema_version else {
      raise BadRequest(
        message="database requires migration; start the matching web service first",
      )
    }
    match command {
      "ssh-authorized-key" => {
        guard cli_value(options, "system-user") == "git" else { return 0 }
        let key = parse_ssh_public_key(
          "\{cli_value(options, "type")} \{cli_value(options, "key")}",
        ) catch {
          _ => return 0
        }
        if authorized_ssh_key(pool, key) is Some(line) {
          println(line)
        }
      }
      "ssh-serve" =>
        return serve_git_ssh(
          pool,
          cli_key_id(options),
          cli_value(matches, "root"),
        )
      "ssh-key-add" => {
        let user = active_user_by_name(pool, cli_value(options, "user"))
        let text = match single_value(options, "file") {
          Some(path) => @fs.read_file(path).text()
          None => @stdio.stdin.read_all().text()
        }
        let key = parse_ssh_public_key(text)
        let id = add_ssh_key(pool, user, cli_value(options, "title"), key)
        println("\{id}\t\{user.name_key}\t\{key.fingerprint}")
      }
      "ssh-key-list" => {
        let user = single_value(options, "user").unwrap_or("")
        pool.with_client(client => {
          let rows = client.query_all(
            (
              #|SELECT ssh_key.id, "user".name_key, ssh_key.title, ssh_key.fingerprint,
              #|  ssh_key.last_used_at, ssh_key.revoked_at
              #|FROM ssh_key JOIN "user" ON "user".id = ssh_key.user_id
              #|WHERE ? = '' OR "user".name_key = ? ORDER BY ssh_key.id
            ),
            params=[user, user],
          )
          println("ID\tUSER\tTITLE\tFINGERPRINT\tLAST_USED\tREVOKED")
          for row in rows {
            let id : Int64 = row.get_name("id")
            let name : String = row.get_name("name_key")
            let title : String = row.get_name("title")
            let fingerprint : String = row.get_name("fingerprint")
            let last_used : String? = row.get_name("last_used_at")
            let revoked : String? = row.get_name("revoked_at")
            println(
              "\{id}\t\{name}\t\{title}\t\{fingerprint}\t\{last_used.unwrap_or("-")}\t\{revoked.unwrap_or("-")}",
            )
          }
        })
      }
      "ssh-key-revoke" => {
        let id = cli_key_id(options)
        let changed = pool.with_client(client => {
          client.execute(
            "UPDATE ssh_key SET revoked_at = datetime('now') WHERE id = ? AND revoked_at IS NULL",
            params=[id],
          )
        })
        guard changed == 1 else {
          raise NotFound(message="active SSH key not found")
        }
        println("Revoked SSH key \{id}")
      }
      "repo-create" => {
        let repo = parse_transport_repo(cli_value(options, "repository"))
        create_managed_repository(
          pool,
          cli_value(matches, "root"),
          repo,
          cli_value(options, "visibility"),
          options.flags.get("import").unwrap_or(false),
        )
        println("Registered \{repo.path()}")
      }
      _ => raise BadRequest(message="unknown management command")
    }
    0
  })
}
