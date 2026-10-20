///|
fn command() -> @argparse.Command {
  let options = [
    @argparse.OptionArg(
      "server",
      long="server",
      env="MOONHUB_SERVER",
      global=true,
    ),
    @argparse.OptionArg("token-file", long="token-file", global=true),
    @argparse.OptionArg(
      "repo",
      long="repo",
      env="MOONHUB_REPOSITORY",
      global=true,
    ),
    @argparse.OptionArg("page", long="page", default_values=["1"], global=true),
    @argparse.OptionArg(
      "status",
      long="status",
      default_values=["open"],
      global=true,
    ),
    @argparse.OptionArg(
      "filter",
      long="filter",
      default_values=["unread"],
      global=true,
    ),
    @argparse.OptionArg("title", long="title", global=true),
    @argparse.OptionArg("body-file", long="body-file", global=true),
    @argparse.OptionArg("file", long="file", global=true),
    @argparse.OptionArg("source", long="source", global=true),
    @argparse.OptionArg("target", long="target", global=true),
    @argparse.OptionArg("version", long="version", global=true),
    @argparse.OptionArg("edit-version", long="edit-version", global=true),
    @argparse.OptionArg("decision", long="decision", global=true),
    @argparse.OptionArg("reviewer", long="reviewer", global=true),
    @argparse.OptionArg("comment", long="comment", global=true),
    @argparse.OptionArg("commit", long="commit", global=true),
    @argparse.OptionArg("path", long="path", global=true),
    @argparse.OptionArg("side", long="side", global=true),
    @argparse.OptionArg("start-line", long="start-line", global=true),
    @argparse.OptionArg("end-line", long="end-line", global=true),
    @argparse.OptionArg("discussion", long="discussion", global=true),
    @argparse.OptionArg("state-version", long="state-version", global=true),
    @argparse.OptionArg("assignee", long="assignee", global=true),
    @argparse.OptionArg("workflow", long="workflow", global=true),
    @argparse.OptionArg("branch", long="branch", global=true),
    @argparse.OptionArg("attempt", long="attempt", global=true),
    @argparse.OptionArg(
      "after",
      long="after",
      default_values=["0"],
      global=true,
    ),
  ]
  @argparse.Command(
    "moonhub",
    options~,
    flags=[
      @argparse.FlagArg("allow-http", long="allow-http", global=true),
      @argparse.FlagArg("json", long="json", global=true),
      @argparse.FlagArg("draft", long="draft", global=true),
    ],
    subcommand_required=true,
    subcommands=[
      @argparse.Command("attachment", subcommand_required=true, subcommands=[
        @argparse.Command("upload"),
      ]),
      @argparse.Command("auth", subcommand_required=true, subcommands=[
        @argparse.Command("login"),
        @argparse.Command("status"),
        @argparse.Command("logout"),
      ]),
      @argparse.Command(
        "mr",
        subcommand_required=true,
        subcommands=[
          @argparse.Command("list"),
          @argparse.Command("create"),
          ..[
            "view", "diff", "checks", "comment", "review", "request-review", "merge",
            "approve-checks", "close", "reopen", "draft", "ready", "edit", "delete-comment",
            "restore-comment", "discussions", "inline-comment", "reply", "resolve-discussion",
            "reopen-discussion",
          ].map(action => {
            @argparse.Command(action, positionals=[
              @argparse.PositionArg("number"),
            ])
          }),
        ],
      ),
      @argparse.Command(
        "issue",
        subcommand_required=true,
        subcommands=[
          @argparse.Command("list"),
          @argparse.Command("create"),
          ..["view", "comment", "close", "reopen", "edit"].map(action => {
            @argparse.Command(action, positionals=[
              @argparse.PositionArg("number"),
            ])
          }),
        ],
      ),
      @argparse.Command(
        "ci",
        subcommand_required=true,
        subcommands=[
          @argparse.Command("list"),
          @argparse.Command("run"),
          ..["view", "logs", "rerun", "cancel"].map(action => {
            @argparse.Command(action, positionals=[
              @argparse.PositionArg("number"),
            ])
          }),
        ],
      ),
      @argparse.Command("inbox", subcommands=[
        @argparse.Command("list"),
        @argparse.Command("read", positionals=[@argparse.PositionArg("number")]),
      ]),
    ],
  )
}

///|
fn option(matches : @argparse.Matches, name : String) -> String? {
  match matches.values.get(name) {
    Some(values) => values.get(0).filter(value => !value.is_empty())
    None => None
  }
}

///|
fn required(
  matches : @argparse.Matches,
  name : String,
) -> String raise CliError {
  option(matches, name).unwrap_or_else(() => {
    raise Invalid("--\{name} is required")
  })
}

///|
async fn read_body(matches : @argparse.Matches) -> String {
  match option(matches, "body-file") {
    None => ""
    Some(path) => {
      guard @fs.kind(path, follow_symlink=false) is Regular &&
        @fs.file_size(path) <= 16777216L else {
        raise Invalid(
          "body file must be a regular UTF-8 file of at most 16 MiB (20,000 characters after image upload)",
        )
      }
      @fs.read_file(path).text()
    }
  }
}

///|
fn credential_file() -> String raise CliError {
  let root = @env.get_env_var("XDG_CONFIG_HOME")
    .filter(value => !value.is_empty())
    .unwrap_or_else(() => @env.get_env_var("HOME").unwrap_or(".") + "/.config")
  guard root.has_prefix("/") else {
    raise Invalid("HOME or XDG_CONFIG_HOME must name an absolute directory")
  }
  root + "/moonhub/auth.json"
}

///|
async fn read_credentials() -> (String, String)? {
  let path = credential_file()
  if !@fs.exists(path) {
    return None
  }
  guard @fs.kind(path, follow_symlink=false) is Regular &&
    @fs.file_size(path) <= 4096L else {
    raise Invalid("invalid credential file")
  }
  let json = @json.parse(@fs.read_file(path).text()) catch {
    _ => raise Invalid("invalid credential file")
  }
  match json {
    { "server": String(server), "token": String(token), .. } =>
      Some((server, token))
    _ => raise Invalid("invalid credential file")
  }
}

///|
pub async fn run(args : ArrayView[String]) -> Int32 {
  let matches = command().parse(argv=args, env=@env.get_env_vars()) catch {
    err => raise Invalid(err.to_string())
  }
  guard matches.subcommand is Some((group, group_options)) else { return 2 }
  let (action, options) = group_options.subcommand.unwrap_or(
    ("list", group_options),
  )
  let allow_http = matches.flags.get("allow-http").unwrap_or(false)
  if group == "auth" && action == "logout" {
    let file = credential_file()
    if @fs.exists(file) {
      @fs.remove(file)
    }
    println("Signed out locally.")
    return 0
  }
  let environment_token = @env.get_env_var("MOONHUB_TOKEN").filter(value => {
    !value.is_empty()
  })
  let saved = if option(matches, "server") is Some(_) &&
    (option(matches, "token-file") is Some(_) || environment_token is Some(_)) {
    None
  } else {
    read_credentials()
  }
  let server = validate_server(
    option(matches, "server").unwrap_or(
      saved.map(value => value.0).unwrap_or(""),
    ),
    allow_http,
  )
  let token = if option(matches, "token-file") is Some(path) {
    guard @fs.kind(path, follow_symlink=false) is Regular &&
      @fs.file_size(path) <= 256L else {
      raise Invalid("token file must be regular and small")
    }
    @fs.read_file(path).text().trim().to_owned()
  } else {
    environment_token.unwrap_or(
      saved
      .filter(value => value.0 == server)
      .map(value => value.1)
      .unwrap_or(""),
    )
  }
  if group == "auth" {
    let user = request(server, token, "/user", None, allow_http~)
    if action == "login" {
      let path = credential_file()
      // Derive the parent without string trimming's character-set semantics.
      let directory = path[:path.length() - 10].to_owned()
      if @fs.exists(directory) {
        guard @fs.kind(directory, follow_symlink=false) is Directory else {
          raise Invalid("credential directory must not be a symlink")
        }
      } else {
        @fs.mkdir(directory, recursive=true, permission=0o700)
      }
      @fs.chmod(directory, 0o700)
      guard @env.rand(16) is Some(random) else {
        raise Invalid("secure randomness unavailable")
      }
      let suffix = StringBuilder()
      for byte in random {
        suffix.write_string(byte.to_int().to_string(radix=16))
      }
      let temporary = directory + "/auth.pending." + suffix.to_string()
      errdefer (@fs.remove(temporary) catch { _ => () })
      @fs.write_file(
        temporary,
        (
          { "server": validate_server(server, allow_http), "token": token } :
          Json).stringify(),
        create_mode=CreateNew,
        permission=0o600,
      )
      @fs.rename(temporary, path, replace=true)
      if !matches.flags.get("json").unwrap_or(false) {
        println("Signed in. Credential saved with private permissions.")
      }
    }
    println(user.stringify())
    return 0
  }
  let repo = if group == "inbox" {
    ""
  } else {
    @domain.parse_transport_repo(discover_repo(server, option(matches, "repo"))).path()
  }
  let base = "/repos/" + repo
  if group == "attachment" && action == "upload" {
    let path = required(matches, "file")
    guard @fs.kind(path, follow_symlink=false) is Regular &&
      @fs.file_size(path) > 0L &&
      @fs.file_size(path) <= 26214400L else {
      raise Invalid(
        "attachment must be a regular file between 1 byte and 25 MiB",
      )
    }
    let filename = path.split("/").collect().last().unwrap().to_owned()
    let result = request(
      server,
      token,
      "\{base}/attachments?filename=\{escape(filename)}",
      None,
      allow_http~,
      raw_body=@fs.read_file(path).binary(),
    )
    if matches.flags.get("json").unwrap_or(false) {
      println(result.stringify())
    } else {
      guard result is { "markdown": String(markdown), .. } else {
        raise InvalidResponse
      }
      println(terminal_text(markdown))
    }
    return 0
  }
  let id = option(options, "number").map(decimal).unwrap_or("")
  let (path, body) : (String, Json?) = match (group, action) {
    ("mr", "list") =>
      (
        "\{base}/mrs?status=\{escape(required(matches, "status"))}&page=\{decimal(required(matches, "page"))}",
        None,
      )
    ("mr", "view") => ("\{base}/mrs/\{id}", None)
    ("mr", "diff") =>
      (
        "\{base}/mrs/\{id}/diff?version=\{decimal(required(matches, "version"))}" +
        option(matches, "commit")
        .map(commit => "&commit=" + escape(commit))
        .unwrap_or(""),
        None,
      )
    ("mr", "checks") => ("\{base}/mrs/\{id}/checks", None)
    ("mr", "discussions") => {
      let selection = match option(matches, "discussion") {
        Some(id) => "discussion=" + decimal(id)
        None =>
          "filter=" +
          escape(
            if required(matches, "filter") == "unread" {
              "all"
            } else {
              required(matches, "filter")
            },
          )
      }
      (
        "\{base}/mrs/\{id}/discussions?\{selection}&page=\{decimal(required(matches, "page"))}",
        None,
      )
    }
    ("mr", "inline-comment") =>
      (
        "\{base}/mrs/\{id}/inline-comment",
        Some({
          "version": decimal(required(matches, "version")),
          "commit": option(matches, "commit").unwrap_or(""),
          "path": required(matches, "path"),
          "side": required(matches, "side"),
          "start_line": decimal(required(matches, "start-line")),
          "end_line": decimal(
            option(matches, "end-line").unwrap_or(
              required(matches, "start-line"),
            ),
          ),
          "body": read_body(matches),
        }),
      )
    ("mr", "reply") =>
      (
        "\{base}/mrs/\{id}/reply",
        Some({
          "discussion": decimal(required(matches, "discussion")),
          "body": read_body(matches),
        }),
      )
    ("mr", "resolve-discussion" | "reopen-discussion") =>
      (
        "\{base}/mrs/\{id}/\{action}",
        Some({
          "discussion": decimal(required(matches, "discussion")),
          "state_version": decimal(required(matches, "state-version")),
        }),
      )
    ("mr", "edit") => {
      let fields : Map[String, Json] = {
        "edit_version": Json(decimal(required(matches, "edit-version"))),
      }
      if option(matches, "title") is Some(title) {
        fields["title"] = Json(title)
      }
      if option(matches, "body-file") is Some(_) {
        fields["description"] = Json(read_body(matches))
      }
      guard fields.length() > 1 else {
        raise Invalid("mr edit requires --title or --body-file")
      }
      ("\{base}/mrs/\{id}/edit", Some(Json::object(fields)))
    }
    ("mr", "delete-comment" | "restore-comment") =>
      (
        "\{base}/mrs/\{id}/\{action}",
        Some({
          "comment": decimal(required(matches, "comment")),
          "version": decimal(required(matches, "version")),
        }),
      )
    ("mr", "create") =>
      (
        "\{base}/mrs",
        Some({
          "title": required(matches, "title"),
          "description": read_body(matches),
          "source": required(matches, "source"),
          "target": required(matches, "target"),
          "draft": if matches.flags.get("draft").unwrap_or(false) {
            "true"
          } else {
            "false"
          },
        }),
      )
    ("mr", "review" | "comment") =>
      (
        "\{base}/mrs/\{id}/\{action}",
        Some({
          "version": decimal(required(matches, "version")),
          "decision": if action == "comment" {
            "comment"
          } else {
            required(matches, "decision")
          },
          "body": read_body(matches),
        }),
      )
    ("mr", "request-review") =>
      (
        "\{base}/mrs/\{id}/request-review",
        Some({
          "version": decimal(required(matches, "version")),
          "reviewer": decimal(required(matches, "reviewer")),
        }),
      )
    ("mr", "merge" | "approve-checks") =>
      (
        "\{base}/mrs/\{id}/\{action}",
        Some({ "version": decimal(required(matches, "version")) }),
      )
    ("mr", "close" | "reopen" | "draft" | "ready") =>
      (
        "\{base}/mrs/\{id}/\{action}",
        Some({ "edit_version": decimal(required(matches, "edit-version")) }),
      )
    ("issue", "list") =>
      (
        "\{base}/issues?status=\{escape(required(matches, "status"))}&page=\{decimal(required(matches, "page"))}",
        None,
      )
    ("issue", "view") => ("\{base}/issues/\{id}", None)
    ("issue", "create") =>
      (
        "\{base}/issues",
        Some({
          "title": required(matches, "title"),
          "description": read_body(matches),
          "assignee": option(matches, "assignee").unwrap_or("0"),
        }),
      )
    ("issue", "comment") =>
      ("\{base}/issues/\{id}/comment", Some({ "body": read_body(matches) }))
    ("issue", "close" | "reopen") =>
      (
        "\{base}/issues/\{id}/\{action}",
        Some({ "edit_version": decimal(required(matches, "edit-version")) }),
      )
    ("issue", "edit") => {
      let fields : Map[String, Json] = {
        "edit_version": Json(decimal(required(matches, "edit-version"))),
      }
      if option(matches, "title") is Some(title) {
        fields.set("title", Json(title))
      }
      if option(matches, "body-file") is Some(_) {
        fields.set("description", Json(read_body(matches)))
      }
      if option(matches, "assignee") is Some(assignee) {
        fields.set("assignee", Json(assignee))
      }
      guard fields.length() > 1 else {
        raise Invalid("issue edit requires --title, --body-file or --assignee")
      }
      ("\{base}/issues/\{id}/edit", Some(Json(fields)))
    }
    ("ci", "list") => ("\{base}/runs", None)
    ("ci", "view") => ("\{base}/runs/\{id}", None)
    ("ci", "logs") =>
      (
        "\{base}/runs/\{id}/logs/\{decimal(required(matches, "attempt"))}?after=\{escape(required(matches, "after"))}",
        None,
      )
    ("ci", "run") =>
      (
        "\{base}/runs",
        Some({
          "branch": required(matches, "branch"),
          "workflow": required(matches, "workflow"),
        }),
      )
    ("ci", "rerun" | "cancel") => ("\{base}/runs/\{id}/\{action}", Some({}))
    ("inbox", "list") =>
      (
        "/inbox?filter=\{escape(required(matches, "filter"))}&page=\{decimal(required(matches, "page"))}",
        None,
      )
    ("inbox", "read") => ("/inbox/\{id}/read", Some({}))
    _ => raise Invalid("unsupported command")
  }
  let result = request(server, token, path, body, allow_http~)
  if matches.flags.get("json").unwrap_or(false) {
    println(result.stringify())
  } else {
    render(result)
  }
  0
}

///|
fn render(json : Json) -> Unit {
  match json {
    { "patch": String(patch), .. } =>
      println(terminal_text(patch, multiline=true))
    { "chunks": Array(chunks), .. } =>
      for chunk in chunks {
        if chunk is { "text": String(text), .. } {
          println(terminal_text(text, multiline=true))
        }
      }
    { "items": Array(items), .. } =>
      for item in items {
        render(item)
      }
    { "mr": item, .. } | { "issue": item, .. } | { "run": item, .. } => {
      render(item)
      println(json.stringify())
    }
    {
      "number": String(number),
      "title": String(title),
      "status": String(status),
      ..
    } => println("\{number}\t\{status}\t\{terminal_text(title)}")
    {
      "number": String(number),
      "name": String(name),
      "status": String(status),
      ..
    } => println("\{number}\t\{status}\t\{terminal_text(name)}")
    { "title": String(title), "kind": String(kind), .. } =>
      println("\{kind}\t\{terminal_text(title)}")
    _ => println(json.stringify())
  }
}

///|
fn remote_repo(remote : String, server : String) -> String? {
  let authority = server.split("://").nth(1).unwrap_or("")
  let host = authority.split(":").next().unwrap_or(authority)
  let mut path = ""
  if remote.has_prefix("ssh://") ||
    remote.has_prefix("https://") ||
    remote.has_prefix("http://") {
    let prefix = remote.find("://").unwrap() + 3
    let rest = remote[prefix:]
    guard rest.split_once("/") is Some((remote_authority, repository)) else {
      return None
    }
    let remote_host = remote_authority
      .split("@")
      .last()
      .unwrap_or(remote_authority)
      .split(":")
      .next()
      .unwrap_or("")
    guard remote_host == host else { return None }
    path = repository.to_owned()
  } else if remote.split_once(":") is Some((remote_authority, repository)) {
    guard remote_authority.split("@").last().unwrap_or(remote_authority) == host else {
      return None
    }
    path = repository.to_owned()
  } else {
    return None
  }
  if path.has_suffix(".git") {
    path = path[:path.length() - 4].to_owned()
  }
  Some(@domain.parse_transport_repo(path).path() catch { _ => return None })
}

///|
async fn discover_repo(server : String, explicit : String?) -> String {
  if explicit is Some(repo) {
    return repo
  }
  for key in ["remote.origin.pushurl", "remote.origin.url"] {
    let (code, stdout, _) = @async.with_timeout(5000, () => {
      @process.collect_output("git", ["config", "--get-all", key], extra_env={
        "GIT_TERMINAL_PROMPT": "0",
      })
    }) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => continue
    }
    if code == 0 {
      for line in stdout.text().split("\n") {
        if remote_repo(line.trim().to_owned(), server) is Some(repo) {
          return repo
        }
      }
    }
  }
  raise Invalid("--repo OWNER/NAME is required outside a matching Git checkout")
}
