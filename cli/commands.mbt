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
    @argparse.OptionArg(
      "body-file",
      long="body-file",
      global=true,
      about="UTF-8 description/comment file. MR descriptions: Closes #123, Fixes #123 or Resolves #123 closes same-repository issues after a successful merge; mr view --json exposes closing_issue_numbers.",
    ),
    @argparse.OptionArg("file", long="file", global=true),
    @argparse.OptionArg("delivery", long="delivery", global=true),
    @argparse.OptionArg("source", long="source", global=true),
    @argparse.OptionArg("target", long="target", global=true),
    @argparse.OptionArg("version", long="version", global=true),
    @argparse.OptionArg("edit-version", long="edit-version", global=true),
    @argparse.OptionArg("decision", long="decision", global=true),
    @argparse.OptionArg("reviewer", long="reviewer", global=true),
    @argparse.OptionArg("comment", long="comment", global=true),
    ..[
      "format", "file-id", "mode", "ignore-comments", "ignore-tests", "document-id",
      "hunk-id", "diff-page",
    ].map(name => @argparse.OptionArg(name, long=name, global=true)),
    @argparse.OptionArg("commit", long="commit", global=true),
    @argparse.OptionArg("path", long="path", global=true),
    @argparse.OptionArg("side", long="side", global=true),
    @argparse.OptionArg("start-line", long="start-line", global=true),
    @argparse.OptionArg("end-line", long="end-line", global=true),
    @argparse.OptionArg("discussion", long="discussion", global=true),
    @argparse.OptionArg("state-version", long="state-version", global=true),
    @argparse.OptionArg("assignee", long="assignee", global=true),
    @argparse.OptionArg("workflow", long="workflow", global=true),
    @argparse.OptionArg("inputs-file", long="inputs-file", global=true),
    @argparse.OptionArg("jobs", long="jobs", global=true),
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
      @argparse.Command("variable", subcommand_required=true, subcommands=[
        @argparse.Command("list"),
        @argparse.Command("set", positionals=[@argparse.PositionArg("name")]),
        @argparse.Command("delete", positionals=[@argparse.PositionArg("name")]),
      ]),
      @argparse.Command("secret", subcommand_required=true, subcommands=[
        @argparse.Command("list"),
        @argparse.Command("set", positionals=[@argparse.PositionArg("name")]),
        @argparse.Command("delete", positionals=[@argparse.PositionArg("name")]),
      ]),
      @argparse.Command(
        "webhook",
        subcommand_required=true,
        subcommands=[
          @argparse.Command("list"),
          @argparse.Command("create"),
          ..["edit", "deliveries", "delivery", "redeliver", "ping", "delete"].map(action => {
              @argparse.Command(action, positionals=[
                @argparse.PositionArg("number"),
              ])
            },
          ),
        ],
      ),
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
        about="Manage merge requests. Use Closes #123, Fixes #123 or Resolves #123 in the description to close same-repository issues after successful merge. Inspect closing_issue_numbers with mr view --json.",
        subcommand_required=true,
        subcommands=[
          @argparse.Command("list"),
          @argparse.Command(
            "create",
            about="Create an MR. Use --body-file with Closes #123 to close the issue after successful merge.",
          ),
          ..[
            "view", "diff", "checks", "comment", "review", "request-review", "merge",
            "approve-checks", "close", "reopen", "draft", "ready", "edit", "delete-comment",
            "restore-comment", "discussions", "inline-comment", "reply", "resolve-discussion",
            "reopen-discussion",
          ].map(action => {
            @argparse.Command(
              action,
              about=match action {
                "edit" =>
                  "Edit MR metadata with --edit-version. Add/remove Closes #123 in --body-file to change which issues close after successful merge."
                "merge" =>
                  "Submit the observed --version for merge. Successful merge closes issues declared by Closes/Fixes/Resolves #123 in the description; inspect closing_issue_numbers with mr view --json first."
                "view" =>
                  "View an MR; --json includes closing_issue_numbers parsed from its description. Missing/already closed issues are skipped at merge."
                _ => ""
              },
              positionals=[@argparse.PositionArg("number")],
            )
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
async fn read_dispatch_inputs(path : String) -> Map[String, Json] {
  guard @fs.kind(path, follow_symlink=false) is Regular &&
    @fs.file_size(path) <= 65535L else {
    raise Invalid(
      "inputs file must be a regular UTF-8 JSON file of at most 65,535 bytes",
    )
  }
  let value = @json.parse(@utf8.decode(@fs.read_file(path).binary())) catch {
    _ => raise Invalid("inputs file must contain valid UTF-8 JSON")
  }
  guard value is Object(inputs) &&
    inputs.length() <= 25 &&
    inputs
    .values()
    .all(value => {
      match value {
        String(_) | True | False | Number(_, ..) => true
        _ => false
      }
    }) else {
    raise Invalid(
      "inputs file must contain an object of at most 25 string, boolean or number values",
    )
  }
  inputs
}

///|
async fn read_variable_value(path : String) -> String {
  guard @fs.kind(path, follow_symlink=false) is Regular &&
    @fs.file_size(path) <= 49152L else {
    raise Invalid(
      "variable file must be a regular UTF-8 file of at most 48 KiB",
    )
  }
  let value = @utf8.decode(@fs.read_file(path).binary()) catch {
    _ => raise Invalid("variable file must contain valid UTF-8")
  }
  guard !value.contains("\u{0000}") else {
    raise Invalid("variable value must not contain NUL characters")
  }
  value
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
    ("variable", "list") => ("\{base}/variables", None)
    ("variable", "set") => {
      let name = required(options, "name")
      let version = required(matches, "version")
      (
        "\{base}/variables/\{escape(name)}",
        Some({
          "value": read_variable_value(required(matches, "body-file")),
          "version": if version == "0" {
            "0"
          } else {
            decimal(version)
          },
        }),
      )
    }
    ("variable", "delete") =>
      (
        "\{base}/variables/\{escape(required(options, "name"))}/delete",
        Some({ "version": decimal(required(matches, "version")) }),
      )
    ("secret", "list") => ("\{base}/secrets", None)
    ("secret", "set") => {
      let name = required(options, "name")
      let version = required(matches, "version")
      let fields : Map[String, Json] = {
        "branch": Json(required(matches, "branch")),
        "workflow": Json(required(matches, "workflow")),
        "version": Json(if version == "0" { "0" } else { decimal(version) }),
      }
      if option(matches, "body-file") is Some(file) {
        guard @fs.kind(file, follow_symlink=false) is Regular &&
          @fs.file_size(file) <= 16384L else {
          raise Invalid(
            "secret file must be a regular UTF-8 file of at most 16 KiB",
          )
        }
        fields["value"] = Json(@fs.read_file(file).text())
      }
      ("\{base}/secrets/\{escape(name)}", Some(Json::object(fields)))
    }
    ("secret", "delete") =>
      (
        "\{base}/secrets/\{escape(required(options, "name"))}/delete",
        Some({ "version": decimal(required(matches, "version")) }),
      )
    ("webhook", "list") => ("\{base}/hooks", None)
    ("webhook", "create" | "edit") => {
      let file = required(matches, "body-file")
      guard @fs.kind(file, follow_symlink=false) is Regular &&
        @fs.file_size(file) <= 65536L else {
        raise Invalid("webhook JSON file must be regular and at most 64 KiB")
      }
      let body = @json.parse(@fs.read_file(file).text()) catch {
        _ => raise Invalid("invalid webhook JSON file")
      }
      guard body is Object(_) else {
        raise Invalid("webhook JSON object required")
      }
      (
        "\{base}/hooks" + (if action == "edit" { "/\{id}" } else { "" }),
        Some(body),
      )
    }
    ("webhook", "deliveries") =>
      (
        "\{base}/hooks/\{id}/deliveries?page=\{decimal(required(matches,"page"))}",
        None,
      )
    ("webhook", "delivery") =>
      (
        "\{base}/hooks/\{id}/deliveries/\{decimal(required(matches,"delivery"))}",
        None,
      )
    ("webhook", "redeliver") =>
      (
        "\{base}/hooks/\{id}/deliveries/\{decimal(required(matches,"delivery"))}/redeliver",
        Some({}),
      )
    ("webhook", "ping") => ("\{base}/hooks/\{id}/ping", Some({}))
    ("webhook", "delete") =>
      (
        "\{base}/hooks/\{id}/delete",
        Some({ "version": decimal(required(matches, "version")) }),
      )
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
        .unwrap_or("") +
        ["format", "file-id", "mode", "ignore-comments", "ignore-tests"]
        .iter()
        .filter_map(name => {
          option(matches, name).map(value => {
            "&" + name.replace(old="-", new="_") + "=" + escape(value)
          })
        })
        .collect()
        .join("") +
        "&page=" +
        decimal(required(matches, "page")),
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
    ("mr", "inline-comment") => {
      let fields : Map[String, Json] = {
        "version": decimal(required(matches, "version")),
        "commit": option(matches, "commit").unwrap_or(""),
        "path": required(matches, "path"),
        "side": required(matches, "side"),
        "start_line": decimal(required(matches, "start-line")),
        "end_line": decimal(
          option(matches, "end-line").unwrap_or(required(matches, "start-line")),
        ),
        "body": read_body(matches),
      }
      for
        key in [
          "document-id", "file-id", "hunk-id", "diff-page", "mode", "ignore-comments",
          "ignore-tests",
        ] {
        if option(matches, key) is Some(value) {
          fields.set(key.replace(old="-", new="_"), Json(value))
        }
      }
      ("\{base}/mrs/\{id}/inline-comment", Some(Json(fields)))
    }
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
      if option(matches, "target") is Some(target) {
        fields["target"] = Json(target)
      }
      guard fields.length() > 1 else {
        raise Invalid("mr edit requires --title, --body-file or --target")
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
    ("ci", "run") => {
      let fields : Map[String, Json] = {
        "branch": Json(required(matches, "branch")),
        "workflow": Json(required(matches, "workflow")),
      }
      if option(matches, "inputs-file") is Some(path) {
        fields["inputs"] = Json(read_dispatch_inputs(path))
      }
      if option(matches, "jobs") is Some(value) {
        fields["jobs"] = ToJson::to_json(
          value.split(",").map(id => id.trim().to_owned()).collect(),
        )
      }
      ("\{base}/runs", Some(Json(fields)))
    }
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
    { "protocol": String("moonhub-diff/1"), .. } => render_structured_diff(json)
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

///|
fn render_structured_diff(json : Json) -> Unit {
  match json {
    { "files": Array(files), .. } =>
      for file in files {
        match file {
          {
            "id": String(id),
            "status": String(status),
            "old_path": String(old),
            "new_path": String(new),
            ..
          } => {
            println(terminal_text("\{id}\t\{status}\t\{old} → \{new}"))
            if file is { "path_error": String(message), .. } {
              println(terminal_text("  " + message))
            }
          }
          _ => ()
        }
      }
    { "error": String(error), .. } => println(terminal_text(error))
    { "document": value, .. } => {
      let document : @diff_protocol.Document = @json.from_json(value) catch {
        _ => {
          println(terminal_text(json.stringify()))
          return
        }
      }
      if json
        is {
          "file": {
            "old_path": String(old),
            "new_path": String(new),
            "old_mode": String(old_mode),
            "new_mode": String(new_mode),
            ..
          },
          ..
        } {
        println(
          terminal_text("\{old} → \{new} · mode \{old_mode} → \{new_mode}"),
        )
      }
      println(terminal_text("\{document.status} · \{document.options.mode}"))
      if document.reordered {
        println(
          "Old declaration order: " +
          document.old_order.map(i => i.to_string()).join(" → "),
        )
        println(
          "New declaration order: " +
          document.new_order.map(i => i.to_string()).join(" → "),
        )
      }
      if document.ignore_reason is Some(reason) {
        println(terminal_text("Filtered: \{reason}"))
      }
      if document.old_eol != document.new_eol ||
        document.old_final_newline != document.new_final_newline {
        println(
          terminal_text(
            "Line endings: \{document.old_eol} → \{document.new_eol}; final newline: \{Repr(document.old_final_newline)} → \{Repr(document.new_final_newline)}",
          ),
        )
      }
      for section in document.sections {
        println(
          terminal_text(
            "Declaration \{section.id} (\{section.kind}): \{section.old_context.unwrap_or("∅")} → \{section.new_context.unwrap_or("∅")}",
          ),
        )
        for reason in section.fallbacks {
          println(terminal_text("Fallback: \{reason}"))
        }
        for hunk in section.hunks {
          println(terminal_text("Hunk \{hunk.id}"))
          for row in hunk.rows {
            for (side, line) in [("old", row.old), ("new", row.new)] {
              if line is Some(line) {
                println(
                  terminal_text(
                    "\{side} \{line.number}: \{line.segments.map(s => s.text).join("")}",
                  ),
                )
              }
            }
          }
        }
      }
    }
    _ => println(terminal_text(json.stringify()))
  }
}
