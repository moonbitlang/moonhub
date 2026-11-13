///|
const CLI_VERSION : String = "0.1.0"

///|
fn command_groups() -> Array[(String, Array[String])] {
  [
    ("auth", ["setup", "login", "status", "logout"]),
    (
      "mr",
      [
        "list", "create", "view", "diff", "checks", "comment", "review", "request-review",
        "merge", "approve-checks", "close", "reopen", "draft", "ready", "edit", "delete-comment",
        "restore-comment", "discussions", "inline-comment", "reply", "resolve-discussion",
        "reopen-discussion",
      ],
    ),
    ("issue", ["list", "create", "view", "comment", "close", "reopen", "edit"]),
    ("ci", ["list", "run", "view", "logs", "rerun", "cancel"]),
    ("inbox", ["list", "read"]),
    ("attachment", ["upload"]),
    (
      "webhook",
      [
        "list", "create", "edit", "deliveries", "delivery", "redeliver", "ping",
        "delete",
      ],
    ),
    ("secret", ["list", "set", "delete"]),
    ("variable", ["list", "set", "delete"]),
  ]
}

///|
fn command_option_names() -> Array[String] {
  [
    "server", "token-file", "repo", "page", "status", "filter", "title", "body-file",
    "file", "delivery", "source", "target", "version", "edit-version", "decision",
    "reviewer", "comment", "format", "file-id", "mode", "ignore-comments", "ignore-tests",
    "document-id", "hunk-id", "diff-page", "commit", "path", "side", "start-line",
    "end-line", "discussion", "state-version", "assignee", "workflow", "inputs-file",
    "jobs", "branch", "attempt", "after",
  ]
}

///|
// Keep legacy global argument placement while exposing relevant options in
// each command's help. Child definitions override visibility, not semantics.
fn client_option(
  name : String,
  hidden~ : Bool = false,
  group~ : String = "",
  action~ : String = "",
) -> @argparse.OptionArg {
  let env : StringView? = match name {
    "server" => Some("MOONHUB_SERVER")
    "repo" => Some("MOONHUB_REPOSITORY")
    _ => None
  }
  let defaults : Array[String]? = match name {
    "page" => Some(["1"])
    "status" => Some(["open"])
    "filter" => Some([if group == "mr" { "all" } else { "unread" }])
    "after" => Some(["0"])
    _ => None
  }
  let default_values = defaults.map(values => values[:])
  @argparse.OptionArg(
    name,
    about=option_description(name, group~),
    env?,
    default_values?,
    global=true,
    hidden~,
    required=required_action_options(group, action).contains(name),
  )
}

///|
fn action_options(group : String, action : String) -> Array[String] {
  match (group, action) {
    ("mr" | "issue", "list") => ["status", "page"]
    ("mr", "create") => ["title", "source", "target", "body-file"]
    ("mr", "diff") =>
      [
        "version", "commit", "format", "file-id", "page", "mode", "ignore-comments",
        "ignore-tests",
      ]
    ("mr", "comment") => ["version", "body-file"]
    ("mr", "review") => ["version", "decision", "body-file"]
    ("mr", "request-review") => ["version", "reviewer"]
    ("mr", "merge") => ["version", "edit-version"]
    ("mr", "approve-checks") => ["version"]
    ("mr" | "issue", "close" | "reopen") | ("mr", "draft" | "ready") =>
      ["edit-version"]
    ("mr", "edit") => ["edit-version", "title", "body-file", "target"]
    ("mr", "delete-comment" | "restore-comment") => ["comment", "version"]
    ("mr", "discussions") => ["discussion", "filter", "page"]
    ("mr", "inline-comment") =>
      [
        "version", "commit", "path", "side", "start-line", "end-line", "body-file",
        "document-id", "file-id", "hunk-id", "diff-page", "mode", "ignore-comments",
        "ignore-tests",
      ]
    ("mr", "reply") => ["discussion", "body-file"]
    ("mr", "resolve-discussion" | "reopen-discussion") =>
      ["discussion", "state-version"]
    ("issue", "create") => ["title", "body-file", "assignee"]
    ("issue", "comment") => ["body-file"]
    ("issue", "edit") => ["edit-version", "title", "body-file", "assignee"]
    ("ci", "run") => ["branch", "workflow", "jobs", "inputs-file"]
    ("ci", "logs") => ["attempt", "after"]
    ("inbox", "list") => ["filter", "page"]
    ("attachment", "upload") => ["file"]
    ("webhook", "create" | "edit") => ["body-file"]
    ("webhook", "deliveries") => ["page"]
    ("webhook", "delivery" | "redeliver") => ["delivery"]
    ("webhook" | "secret" | "variable", "delete") => ["version"]
    ("secret", "set") => ["version", "branch", "workflow", "body-file"]
    ("variable", "set") => ["version", "body-file"]
    _ => []
  }
}

///|
fn required_action_options(group : String, action : String) -> Array[String] {
  match (group, action) {
    ("mr", "create") => ["title", "source", "target"]
    ("mr", "diff" | "merge" | "approve-checks") => ["version"]
    ("mr", "comment") => ["version", "body-file"]
    ("mr", "review") => ["version", "decision"]
    ("mr", "request-review") => ["version", "reviewer"]
    ("mr" | "issue", "edit" | "close" | "reopen") | ("mr", "draft" | "ready") =>
      ["edit-version"]
    ("mr", "delete-comment" | "restore-comment") => ["comment", "version"]
    ("mr", "inline-comment") =>
      ["version", "path", "side", "start-line", "body-file"]
    ("mr", "reply") => ["discussion", "body-file"]
    ("mr", "resolve-discussion" | "reopen-discussion") =>
      ["discussion", "state-version"]
    ("issue", "create") => ["title"]
    ("issue", "comment") => ["body-file"]
    ("ci", "run") => ["branch", "workflow"]
    ("ci", "logs") => ["attempt"]
    ("attachment", "upload") => ["file"]
    ("webhook", "create" | "edit") => ["body-file"]
    ("webhook", "delivery" | "redeliver") => ["delivery"]
    ("webhook" | "secret" | "variable", "delete") => ["version"]
    ("secret", "set") => ["version", "branch", "workflow"]
    ("variable", "set") => ["version", "body-file"]
    _ => []
  }
}

///|
fn command() -> @argparse.Command {
  @argparse.Command(
    "moonhub",
    about="MoonHub CLI \{CLI_VERSION}: merge requests, issues and CI on your MoonHub server.\n\n" +
      setup_instructions("https://your-moonhub-server") +
      "\n\nStart with: moonx hackwaly/moonhub/cmd/moonhub@latest mr list --repo OWNER/NAME\n" +
      "Optional Bash/Zsh shortcut: alias moonhub='moonx hackwaly/moonhub/cmd/moonhub@latest'\n" +
      "Use moonhub help COMMAND or moonhub COMMAND ACTION --help for examples.\n" +
      "MR descriptions can use Closes #123 to close an issue after merge.\n" +
      "Exit codes: 0 success/help, 1 server/network failure, 2 invalid input or missing setup.\n" +
      "Automation: MOONHUB_SERVER, MOONHUB_TOKEN, MOONHUB_REPOSITORY; --json prints API JSON.\n" +
      "Credentials: $XDG_CONFIG_HOME/moonhub/auth.json (default $HOME/.config/moonhub/auth.json).",
    version=CLI_VERSION,
    arg_required_else_help=true,
    subcommand_required=true,
    options=command_option_names().map(name => {
      client_option(
        name,
        hidden=!["server", "token-file", "repo"].contains(name),
      )
    }),
    flags=[
      @argparse.FlagArg(
        "allow-http",
        about="Allow HTTP only for a trusted local test server.",
        global=true,
      ),
      @argparse.FlagArg(
        "json",
        about="Print complete API JSON; IDs and versions are decimal strings.",
        global=true,
      ),
      @argparse.FlagArg(
        "draft",
        about="Create the merge request as a draft.",
        global=true,
        hidden=true,
      ),
    ],
    subcommands=command_groups().map(entry => {
      let (group, actions) = entry
      @argparse.Command(
        group,
        about=command_description(group, ""),
        arg_required_else_help=group != "inbox",
        subcommand_required=group != "inbox",
        options=if group == "inbox" {
          action_options(group, "list").map(name => client_option(name))
        } else {
          []
        },
        subcommands=actions.map(action => {
          let positional = match (group, action) {
            ("secret" | "variable", "set" | "delete") =>
              Some(
                ("name", "Repository secret/variable name, for example REGION."),
              )
            ("mr" | "issue" | "ci", "list" | "create" | "run") => None
            ("mr" | "issue" | "ci", _) =>
              Some(
                (
                  "number", "Resource number from list/view output (positive decimal).",
                ),
              )
            ("webhook", "list" | "create") => None
            ("webhook", _) =>
              Some(("number", "Webhook ID from webhook list --json."))
            ("inbox", "read") =>
              Some(("number", "Notification ID from inbox --json."))
            _ => None
          }
          @argparse.Command(
            action,
            about=command_description(group, action),
            options=action_options(group, action).map(name => {
              client_option(name, group~, action~)
            }),
            flags=if group == "mr" && action == "create" {
              [
                @argparse.FlagArg(
                  "draft",
                  about="Create as a draft; use mr ready to request review.",
                  global=true,
                ),
              ]
            } else {
              []
            },
            positionals=match positional {
              Some((name, about)) =>
                [
                  @argparse.PositionArg(
                    name,
                    about~,
                    num_args=@argparse.ValueRange::single(),
                  ),
                ]
              None => []
            },
          )
        }),
      )
    }),
  )
}
