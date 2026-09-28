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
      @argparse.Command("ssh-pre-receive", hidden=true, positionals=[
        PositionArg("id"),
        PositionArg("repository"),
      ]),
      @argparse.Command("ssh-ref-transaction", hidden=true, positionals=[
        PositionArg("id"),
        PositionArg("repository"),
        PositionArg("push-id"),
        PositionArg("phase"),
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
      @argparse.Command(
        "deploy-key-add",
        about="Bind a new Ed25519 public key to exactly one repository.",
        positionals=[PositionArg("repository")],
        options=[
          OptionArg("actor", long="actor", required=true),
          OptionArg("title", long="title", required=true),
          OptionArg(
            "file",
            long="file",
            required=true,
            about="Public key file.",
          ),
        ],
        flags=[
          FlagArg(
            "write",
            long="write",
            about="Explicitly grant push access; defaults to read-only.",
          ),
        ],
      ),
      @argparse.Command(
        "deploy-key-list",
        about="List repository deploy keys.",
        positionals=[PositionArg("repository")],
        options=[OptionArg("actor", long="actor", required=true)],
      ),
      @argparse.Command(
        "deploy-key-revoke",
        about="Revoke a repository deploy key for subsequent operations.",
        positionals=[PositionArg("repository"), PositionArg("id")],
        options=[OptionArg("actor", long="actor", required=true)],
      ),
      @argparse.Command(
        "pipeline-provider-create",
        about="Register a Docker pipeline provider from a token file.",
        options=[
          OptionArg("name", long="name", required=true),
          OptionArg("token-file", long="token-file", required=true),
          OptionArg("labels", long="labels", default_values=[
            "self-hosted,linux",
          ]),
          OptionArg(
            "scope",
            long="scope",
            default_values=["selected"],
            about="Repository access: selected or all.",
          ),
          OptionArg("repositories", long="repositories", default_values=[""]),
          OptionArg("admin", long="admin", default_values=["root"]),
        ],
      ),
      @argparse.Command(
        "pipeline-provider-ensure",
        about="Idempotently register a Docker pipeline provider from a token file.",
        options=[
          OptionArg("name", long="name", required=true),
          OptionArg("token-file", long="token-file", required=true),
          OptionArg("labels", long="labels", default_values=[
            "self-hosted,linux",
          ]),
          OptionArg(
            "scope",
            long="scope",
            about="Repository access: selected or all. Omit to preserve existing scope.",
          ),
          OptionArg("repositories", long="repositories", default_values=[""]),
          OptionArg("admin", long="admin", default_values=["root"]),
        ],
      ),
      @argparse.Command(
        "pipeline-rerun",
        about="Rerun a completed pipeline from its immutable source snapshot.",
        positionals=[PositionArg("repository"), PositionArg("number")],
        options=[OptionArg("admin", long="admin", default_values=["root"])],
      ),
    ],
  )
}

///|
fn cli_value(matches : @argparse.Matches, name : String) -> String raise {
  guard single_value(matches, name) is Some(value) else {
    raise @domain.BadRequest(message="missing \{name}")
  }
  value
}

///|
fn cli_key_id(matches : @argparse.Matches) -> Int64 raise {
  let value = cli_value(matches, "id")
  let id = @string.parse_int64(value) catch {
    _ => raise @domain.BadRequest(message="invalid SSH key id")
  }
  guard id > 0L else { raise @domain.BadRequest(message="invalid SSH key id") }
  id
}

///|
async fn run_management_cli(args : ArrayView[String]) -> Int {
  let matches = management_command().parse(argv=args, env=@env.get_env_vars())
  guard matches.subcommand is Some((command, options)) else { return 1 }
  let db_path = cli_value(matches, "db")
  guard @fs.exists(db_path) else {
    raise @domain.NotFound(
      message="database not found; start the web service first",
    )
  }
  @async.with_task_group(group => {
    let pool = @database.new_db_pool({ path: db_path, }, group)
    defer pool.close()
    let version : Int64 = pool.with_client(client => {
      guard client.query_opt("PRAGMA user_version") is Some(row) else {
        raise @domain.BadRequest(message="cannot read database schema version")
      }
      row.get_name("user_version")
    })
    guard version == @database.database_schema_version else {
      raise @domain.BadRequest(
        message="database requires migration; start the matching web service first",
      )
    }
    match command {
      "ssh-authorized-key" => {
        guard cli_value(options, "system-user") == "git" else { return 0 }
        let key = @ssh.parse_ssh_public_key(
          "\{cli_value(options, "type")} \{cli_value(options, "key")}",
        ) catch {
          _ => return 0
        }
        if @ssh.authorized_ssh_key(pool, key) is Some(line) {
          println(line)
        }
      }
      "ssh-serve" =>
        return @ssh.serve_git_ssh(
          pool,
          @ssh.SshCredential::parse(cli_value(options, "id")),
          cli_value(matches, "root"),
        )
      "ssh-ref-transaction" =>
        @ssh.record_ref_transaction(
          pool,
          @ssh.SshCredential::parse(cli_value(options, "id")),
          @domain.parse_transport_repo(cli_value(options, "repository")),
          cli_value(options, "push-id"),
          cli_value(options, "phase"),
        )
      "ssh-pre-receive" =>
        @ssh.check_received_refs(
          pool,
          @ssh.SshCredential::parse(cli_value(options, "id")),
          @domain.parse_transport_repo(cli_value(options, "repository")),
        )
      "ssh-key-add" => {
        let user = @identity.active_user_by_name(
          pool,
          cli_value(options, "user"),
        )
        let text = match single_value(options, "file") {
          Some(path) => @fs.read_file(path).text()
          None => @stdio.stdin.read_all().text()
        }
        let key = @ssh.parse_ssh_public_key(text)
        let id = @ssh.add_ssh_key(pool, user, cli_value(options, "title"), key)
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
          raise @domain.NotFound(message="active SSH key not found")
        }
        println("Revoked SSH key \{id}")
      }
      "repo-create" => {
        let repo = @domain.parse_transport_repo(
          cli_value(options, "repository"),
        )
        @repository.create_managed_repository(
          pool,
          cli_value(matches, "root"),
          repo,
          cli_value(options, "visibility"),
          options.flags.get("import").unwrap_or(false),
        )
        println("Registered \{repo.path()}")
      }
      "deploy-key-add" | "deploy-key-list" | "deploy-key-revoke" => {
        let repo = @domain.parse_transport_repo(
          cli_value(options, "repository"),
        )
        let actor = @identity.active_user_by_name(
          pool,
          cli_value(options, "actor"),
        )
        match command {
          "deploy-key-add" => {
            let path = cli_value(options, "file")
            guard @fs.kind(path, follow_symlink=false) is Regular &&
              @fs.file_size(path) <= 16384L else {
              raise @domain.BadRequest(
                message="public key file must be a regular small file",
              )
            }
            let key = @ssh.parse_ssh_public_key(@fs.read_file(path).text())
            let id = @ssh.add_repository_deploy_key(
              pool,
              actor,
              repo,
              cli_value(options, "title"),
              key,
              write_access=options.flags.get("write").unwrap_or(false),
            )
            println("\{id}\t\{repo.path()}\t\{key.fingerprint}")
          }
          "deploy-key-revoke" => {
            let id = cli_key_id(options)
            @ssh.revoke_repository_deploy_key(pool, actor, repo, id)
            println("Revoked deploy key \{id} for \{repo.path()}")
          }
          _ =>
            for key in @ssh.repository_deploy_keys(pool, actor, repo) {
              println(
                "\{key.id}\t\{key.title}\t\{key.fingerprint}\twrite=\{key.write_access}\tcreator=\{key.creator}\t\{key.created_at}\t\{key.last_used_at.unwrap_or("-")}\t\{key.revoked_at.unwrap_or("-")}",
              )
            }
        }
      }
      "pipeline-provider-create" => {
        let token_path = cli_value(options, "token-file")
        guard @fs.kind(token_path, follow_symlink=false) is Regular &&
          @fs.file_size(token_path) <= 256L else {
          raise @domain.BadRequest(
            message="provider token file must be a regular small file",
          )
        }
        let token = @fs.read_file(token_path).text().trim().to_owned()
        let labels = cli_value(options, "labels")
          .split(",")
          .filter(label => !label.trim().is_empty())
          .map(label => label.trim().to_owned())
          .collect()
        let repositories : Array[@domain.RepoId] = []
        for path in cli_value(options, "repositories").split(",") {
          let path = path.trim()
          if !path.is_empty() {
            repositories.push(@domain.parse_transport_repo(path.to_owned()))
          }
        }
        let admin = @identity.active_user_by_name(
          pool,
          cli_value(options, "admin"),
        )
        let provider = @pipeline.Coordinator::new(pool).create_provider(
          admin,
          cli_value(options, "name"),
          token,
          labels,
          repositories,
          scope=@pipeline.ProviderScope::parse(cli_value(options, "scope")),
        )
        println("Registered pipeline provider \{provider.id}:\{provider.name}")
      }
      "pipeline-provider-ensure" => {
        let token_path = cli_value(options, "token-file")
        guard @fs.kind(token_path, follow_symlink=false) is Regular &&
          @fs.file_size(token_path) <= 256L else {
          raise @domain.BadRequest(
            message="provider token file must be a regular small file",
          )
        }
        let token = @fs.read_file(token_path).text().trim().to_owned()
        let labels = cli_value(options, "labels")
          .split(",")
          .filter(label => !label.trim().is_empty())
          .map(label => label.trim().to_owned())
          .collect()
        let repositories : Array[@domain.RepoId] = []
        for path in cli_value(options, "repositories").split(",") {
          let path = path.trim()
          if !path.is_empty() {
            repositories.push(@domain.parse_transport_repo(path.to_owned()))
          }
        }
        let admin = @identity.active_user_by_name(
          pool,
          cli_value(options, "admin"),
        )
        let provider = @pipeline.Coordinator::new(pool).ensure_provider(
          admin,
          cli_value(options, "name"),
          token,
          labels,
          repositories,
          scope=match single_value(options, "scope") {
            Some(value) => Some(@pipeline.ProviderScope::parse(value))
            None => None
          },
        )
        println("Ensured pipeline provider \{provider.id}:\{provider.name}")
      }
      "pipeline-rerun" => {
        let number = @string.parse_int64(cli_value(matches, "number")) catch {
          _ => raise @domain.BadRequest(message="invalid pipeline run number")
        }
        guard number > 0L else {
          raise @domain.BadRequest(message="invalid pipeline run number")
        }
        let repo = @domain.parse_transport_repo(
          cli_value(matches, "repository"),
        )
        let actor = @identity.active_user_by_name(
          pool,
          cli_value(options, "admin"),
        )
        let run = @pipeline.rerun_run(
          pool,
          cli_value(matches, "root"),
          actor,
          repo,
          number,
        )
        println("Rerun pipeline \{repo.path()}#\{run.number}")
      }
      _ => raise @domain.BadRequest(message="unknown management command")
    }
    0
  })
}
