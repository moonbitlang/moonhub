///|
fn option_description(name : String, group~ : String = "") -> String {
  if name == "version" {
    return match group {
      "mr" =>
        "MR version from mr view --json; for delete/restore-comment, use the comment activity's own version."
      "secret" | "variable" =>
        "Current version from \{group} list --json; 0 creates a new value."
      "webhook" => "Current version from webhook list --json."
      _ => "Observed resource revision from view/list --json."
    }
  }
  if name == "filter" && group == "mr" {
    return "Discussion filter: all, unresolved or resolved."
  }
  if name == "filter" && group == "inbox" {
    return "Notification filter: unread, all, reviews or assigned."
  }
  match name {
    "server" =>
      "MoonHub origin, e.g. https://moonhub.example; overrides saved server."
    "token-file" =>
      "Private file containing an mh_ token; overrides MOONHUB_TOKEN and saved login."
    "repo" =>
      "OWNER/NAME; otherwise infer from origin matching the server (requires Git)."
    "page" =>
      "Page number starting at 1; request the next page when has_more is true."
    "status" => "open or closed; MR lists also accept merged."
    "filter" =>
      "Inbox: unread/all/reviews/assigned. MR discussions: all/unresolved/resolved."
    "title" => "Issue or merge request title."
    "body-file" =>
      "UTF-8 description/comment file, or JSON for webhooks. MR Closes #123 closes issues after merge."
    "file" => "Regular file to upload, up to 25 MiB (images up to 5 MiB)."
    "delivery" => "Delivery ID from webhook deliveries --json."
    "source" =>
      "Already-pushed source branch; this client does not push Git branches."
    "target" => "Existing target branch, for example master."
    "edit-version" =>
      "Observed edit_version from mr/issue view --json; protects against stale edits."
    "decision" =>
      "Review decision: approved, changes_requested, withdrawn or comment."
    "reviewer" =>
      "Account ID from mr view --json eligible_reviewers; requires repository membership."
    "comment" =>
      "Comment activity ID from mr view --json; --version is that comment's own version."
    "format" =>
      "Diff format: patch (default) or structured; --json preserves all response fields."
    "file-id" => "Opaque file ID from mr diff --format structured --json."
    "mode" => "Structured diff mode: lexical, ast or line."
    "ignore-comments" =>
      "Structured diff filter, explicit true or false (not a flag)."
    "ignore-tests" =>
      "Structured diff filter, explicit true or false (not a flag)."
    "document-id" =>
      "Document ID from a structured file diff; retain its effective options."
    "hunk-id" => "Hunk ID from the structured file diff being commented on."
    "diff-page" => "Manifest page of the structured file diff (starts at 1)."
    "commit" =>
      "Full lowercase commit SHA in the saved MR revision; omit for all changes."
    "path" => "Repository-relative file path on the selected side of the diff."
    "side" => "old or new side of the diff."
    "start-line" => "First original file line, starting at 1."
    "end-line" =>
      "Last line, inclusive; defaults to --start-line (at most 100 lines)."
    "discussion" => "Discussion ID from mr discussions --json."
    "state-version" =>
      "Observed state_version from mr discussions --discussion ID --json."
    "assignee" => "Account ID, not username; use 0 to remove the assignee."
    "workflow" => "Workflow path, e.g. .github/workflows/build.yml."
    "inputs-file" =>
      "UTF-8 JSON object of up to 25 string/boolean/number workflow inputs."
    "jobs" =>
      "Comma-separated original job IDs; dependencies and matrix children are included."
    "branch" => "Existing branch to run CI on, or to scope a repository secret."
    "attempt" =>
      "Run attempt ID from ci view NUMBER --json (not the attempt ordinal)."
    "after" => "Log cursor; start at 0, then use the returned next_cursor."
    _ => ""
  }
}

///|
fn command_description(group : String, action : String) -> String {
  match (group, action) {
    ("auth", "") => "Set up access tokens, sign in, check identity or sign out."
    ("mr", "") =>
      "Manage merge requests and reviews; Closes #123 closes issues after merge."
    ("issue", "") => "List, create, edit and discuss repository issues."
    ("ci", "") => "Inspect workflow runs and logs; execute tokens control runs."
    ("inbox", "") =>
      "Your notifications and review requests; defaults to list, no --repo needed."
    ("attachment", "") =>
      "Upload a file and print Markdown to use in descriptions or comments."
    ("webhook", "") =>
      "Manage signed webhooks and deliveries; repository manager access required."
    ("secret", "") =>
      "Manage write-only CI secrets; repository owner/admin access required."
    ("variable", "") =>
      "Manage readable CI variables; repository owner/admin access required."
    ("auth", "setup") =>
      "Show token setup instructions for --server; no credentials required."
    ("auth", "login") => "Verify a token and save a private local login."
    ("auth", "status") =>
      "Verify saved/explicit credentials and show account identity."
    ("auth", "logout") =>
      "Delete local credentials; revoke the token separately in account settings."
    ("mr" | "issue" | "ci" | "webhook" | "secret" | "variable", "list") =>
      "List resources; use --json to see IDs, revisions and available metadata."
    ("mr", "create") =>
      "Create from pushed branches; Closes #123 in --body-file closes issues after merge."
    ("mr", "view") =>
      "Show MR details, version, edit_version, activity and closing_issue_numbers."
    ("mr", "diff") =>
      "Show changes for the required observed --version; optionally one --commit."
    ("mr", "checks") => "Show required CI checks and merge readiness."
    ("mr", "comment") =>
      "Post a comment on the required --version using --body-file."
    ("mr", "review") =>
      "Review the required --version with --decision; write token required."
    ("mr", "request-review") =>
      "Request review from an account ID on the required --version."
    ("mr", "merge") =>
      "Queue merge at --version; confirm Closes issue closures with --edit-version; merge token required."
    ("mr", "approve-checks") =>
      "Authorize checks for --version; execute token and manager access required."
    ("mr", "close" | "reopen" | "draft" | "ready") =>
      "Change MR state with the observed --edit-version; write token required."
    ("mr", "edit") =>
      "Edit title, body or target at --edit-version; Closes directives update issue closures at merge."
    ("mr", "delete-comment") =>
      "Hide a plain comment by --comment and its own --version; reversible."
    ("mr", "restore-comment") =>
      "Restore a hidden comment by --comment and its own --version."
    ("mr", "discussions") =>
      "List discussions or read one --discussion, including replies and state_version."
    ("mr", "inline-comment") =>
      "Comment on diff lines with --version, --path, --side, --start-line and --body-file."
    ("mr", "reply") => "Reply to --discussion using a UTF-8 --body-file."
    ("mr", "resolve-discussion" | "reopen-discussion") =>
      "Change --discussion at its observed --state-version."
    ("issue", "create") =>
      "Create an issue with --title; optionally --body-file and an --assignee account ID."
    ("issue", "view") =>
      "Show the issue, comments and edit_version; use --json before editing."
    ("issue", "comment") =>
      "Add a comment from a UTF-8 --body-file; write token required."
    ("issue", "close" | "reopen") =>
      "Change issue state with the observed --edit-version."
    ("issue", "edit") =>
      "Edit title, body or assignee at --edit-version; omitted fields are preserved."
    ("ci", "run") =>
      "Start --workflow on --branch; optional --jobs and --inputs-file; execute token required."
    ("ci", "view") => "Show run status and attempt IDs for ci logs."
    ("ci", "logs") =>
      "Read logs for --attempt; paginate with the returned next_cursor and --after."
    ("ci", "rerun" | "cancel") =>
      "Control a workflow run; execute token and repository manager access required."
    ("inbox", "list") =>
      "List notifications; filters: unread, all, reviews, assigned."
    ("inbox", "read") => "Mark a notification ID as read; write token required."
    ("attachment", "upload") =>
      "Upload --file and print its Markdown; --json returns the full metadata."
    ("webhook", "create") => "Create a webhook from a private JSON --body-file."
    ("webhook", "edit") =>
      "Update a webhook from JSON containing its current version; omit secret to preserve it."
    ("webhook", "deliveries") => "List this webhook's delivery IDs and states."
    ("webhook", "delivery") =>
      "Read one --delivery with bounded request/response details."
    ("webhook", "redeliver") =>
      "Retry one --delivery; may send another request to the webhook endpoint."
    ("webhook", "ping") => "Send a test event to the webhook endpoint."
    ("webhook", "delete") => "Delete the webhook at its observed --version."
    ("secret", "set") =>
      "Save a secret scoped to --branch/--workflow at --version; file optional for updates."
    ("variable", "set") =>
      "Save a readable UTF-8 --body-file at --version; 0 creates, current version updates."
    ("secret" | "variable", "delete") =>
      "Delete the named value at --version from list --json."
    _ => ""
  }
}

///|
fn command_examples(group : String, action : String) -> String {
  let example = match (group, action) {
    ("auth", "" | "setup" | "login") =>
      setup_instructions("https://your-moonhub-server")
    ("auth", "status") =>
      "moonhub auth status --json\nMOONHUB_SERVER and MOONHUB_TOKEN can supply credentials without saving a login."
    ("auth", "logout") =>
      "moonhub auth logout\nServer-side revocation: open YOUR_SERVER/-/settings/tokens."
    ("mr", "") =>
      "moonhub mr list --repo OWNER/NAME\nmoonhub mr view 12 --json\nmoonhub mr diff 12 --version 3\nmoonhub mr review 12 --version 3 --decision approved\nInspect the current version and edit_version with view --json before mutations."
    ("mr", "list") | ("issue", "" | "list") =>
      "moonhub \{group} list --repo OWNER/NAME --status open --page 1\nmoonhub \{group} view 12 --repo OWNER/NAME --json"
    ("mr", "create") =>
      "git push origin feature\nmoonhub mr create --repo OWNER/NAME --source feature --target master --title 'Add feature' --body-file description.md\nPut Closes #123 in description.md to close that issue after successful merge."
    ("mr", "view") =>
      "moonhub mr view 12 --repo OWNER/NAME --json\nUse version for reviews/diffs, edit_version for metadata, and each activity's id/version for comments."
    ("mr", "diff") =>
      "moonhub mr view 12 --json\nmoonhub mr diff 12 --version 3\nmoonhub mr diff 12 --version 3 --format structured --json\nUse --file-id from the manifest to inspect one file; --page selects manifest pages."
    ("mr", "checks") => "moonhub mr checks 12 --repo OWNER/NAME --json"
    ("mr", "comment") =>
      "moonhub mr comment 12 --version 3 --body-file comment.md"
    ("mr", "review") =>
      "moonhub mr view 12 --json\nmoonhub mr review 12 --version 3 --decision approved\nmoonhub mr review 12 --version 3 --decision changes_requested --body-file review.md"
    ("mr", "request-review") =>
      "moonhub mr view 12 --json\nmoonhub mr request-review 12 --version 3 --reviewer 7\nUse an eligible_reviewers account ID, not a username."
    ("mr", "merge") =>
      "moonhub mr view 12 --json\nmoonhub mr checks 12 --json\nmoonhub mr merge 12 --version 3 --edit-version 2\nInspect closing_issue_numbers first. Merge is queued; inspect view/checks for completion."
    ("mr", "approve-checks") =>
      "moonhub mr view 12 --json\nmoonhub mr approve-checks 12 --version 3"
    ("mr", "close" | "reopen" | "draft" | "ready") =>
      "moonhub mr view 12 --json\nmoonhub mr \{action} 12 --edit-version 2"
    ("mr", "edit") =>
      "moonhub mr view 12 --json\nmoonhub mr edit 12 --edit-version 2 --title 'Updated title' --body-file description.md\nEmpty body file clears the description; --target changes the target and refreshes the comparison."
    ("mr", "delete-comment" | "restore-comment") =>
      "moonhub mr view 12 --json\nmoonhub mr \{action} 12 --comment 42 --version 1\nUse the comment activity's own version, not the MR version."
    ("mr", "discussions") =>
      "moonhub mr discussions 12 --filter unresolved --json\nmoonhub mr discussions 12 --discussion 42 --json"
    ("mr", "inline-comment") =>
      "moonhub mr diff 12 --version 3\nmoonhub mr inline-comment 12 --version 3 --path src/main.mbt --side new --start-line 10 --end-line 12 --body-file comment.md\nFor structured diffs, also pass the returned document/file/hunk IDs and effective diff options."
    ("mr", "reply") =>
      "moonhub mr discussions 12 --json\nmoonhub mr reply 12 --discussion 42 --body-file reply.md"
    ("mr", "resolve-discussion" | "reopen-discussion") =>
      "moonhub mr discussions 12 --discussion 42 --json\nmoonhub mr \{action} 12 --discussion 42 --state-version 2"
    ("issue", "create") =>
      "moonhub issue create --repo OWNER/NAME --title 'Track a bug' --body-file issue.md"
    ("issue", "view") => "moonhub issue view 12 --repo OWNER/NAME --json"
    ("issue", "comment") => "moonhub issue comment 12 --body-file comment.md"
    ("issue", "edit") =>
      "moonhub issue view 12 --json\nmoonhub issue edit 12 --edit-version 2 --title 'Updated title'\nEmpty --body-file clears the description; --assignee 0 clears assignment."
    ("issue", "close" | "reopen") =>
      "moonhub issue view 12 --json\nmoonhub issue \{action} 12 --edit-version 2"
    ("ci", "" | "list") =>
      "moonhub ci list --repo OWNER/NAME --json\nmoonhub ci view 9 --json"
    ("ci", "run") =>
      "moonhub ci run --repo OWNER/NAME --branch master --workflow .github/workflows/build.yml\nmoonhub ci run --branch master --workflow .github/workflows/build.yml --jobs build,test --inputs-file inputs.json\ninputs.json example: {\"release\":false,\"version\":\"1.2.3\"}. Selected jobs include dependencies and matrix children."
    ("ci", "view") =>
      "moonhub ci view 9 --repo OWNER/NAME --json\nUse the returned attempt ID for ci logs --attempt."
    ("ci", "logs") =>
      "moonhub ci view 9 --json\nmoonhub ci logs 9 --attempt 14 --after 0 --json\nRepeat with --after NEXT_CURSOR while has_more is true. This command does not watch automatically."
    ("ci", "rerun" | "cancel") =>
      "moonhub ci \{action} 9 --repo OWNER/NAME\nmoonhub ci view 9 --json"
    ("inbox", "" | "list") =>
      "moonhub inbox --filter unread --json\nmoonhub inbox list --filter reviews --page 1 --json\nNo --repo is needed for your inbox."
    ("inbox", "read") => "moonhub inbox --json\nmoonhub inbox read 25"
    ("attachment", "" | "upload") =>
      "moonhub attachment upload --repo OWNER/NAME --file /path/to/report.pdf\nCopy the printed Markdown into a description/comment file, then pass it with --body-file."
    ("webhook", "" | "create" | "edit") =>
      "moonhub webhook list --repo OWNER/NAME --json\nmoonhub webhook \{if action == "edit" { "edit 1" } else { "create" }} --body-file hook.json --json\nPrivate hook.json: {\"url\":\"https://example.com/hook\",\"secret\":\"a-random-secret\",\"events\":[\"push\",\"merge_request\",\"review\",\"workflow_run\"],\"active\":true}\nFor edit, include \"version\":\"2\" from list; omit secret to preserve it."
    ("webhook", "list") => "moonhub webhook list --repo OWNER/NAME --json"
    ("webhook", "deliveries") =>
      "moonhub webhook deliveries 1 --repo OWNER/NAME --page 1 --json"
    ("webhook", "delivery" | "redeliver") =>
      "moonhub webhook deliveries 1 --json\nmoonhub webhook \{action} 1 --delivery 42 --json"
    ("webhook", "ping") => "moonhub webhook ping 1 --repo OWNER/NAME --json"
    ("webhook", "delete") =>
      "moonhub webhook list --json\nmoonhub webhook delete 1 --version 2"
    ("secret" | "variable", "" | "list") =>
      "moonhub \{group} list --repo OWNER/NAME --json\nCreate with --version 0; update/delete with version from this list.\{if group == "secret" { " Secret values are never returned." } else { " Variable values are readable; do not use them for secrets." }}"
    ("secret", "set") =>
      "moonhub secret set TOKEN --repo OWNER/NAME --branch master --workflow .github/workflows/build.yml --body-file /private/token.txt --version 0\nFor updates, use the version from secret list --json. Omitting --body-file preserves an existing value. Never put secret values in arguments."
    ("variable", "set") =>
      "moonhub variable set REGION --repo OWNER/NAME --body-file region.txt --version 0\nValues are readable UTF-8 text (up to 48 KiB). Empty files are allowed. Use list --json to obtain an existing version."
    ("secret" | "variable", "delete") =>
      "moonhub \{group} list --repo OWNER/NAME --json\nmoonhub \{group} delete REGION --repo OWNER/NAME --version 2"
    _ => ""
  }
  if example.is_empty() {
    ""
  } else {
    "\nExamples and notes:\n\{example}\n\nExamples use moonhub; with moonx, replace it with moonx hackwaly/moonhub/cmd/moonhub@latest.\nRepository commands need --repo OWNER/NAME or a Git origin matching the configured server."
  }
}

///|
fn contextual_help(text : String) -> String {
  for line in text.split("\n") {
    if line.has_prefix("Usage: moonhub ") {
      let usage = line.split(" ").collect()
      let group = usage.get(2).unwrap_or("").to_owned()
      let action = usage.get(3).unwrap_or("").to_owned()
      for (name, actions) in command_groups() {
        if group == name {
          return text +
            "\n" +
            command_examples(
              group,
              if actions.contains(action) {
                action
              } else {
                ""
              },
            )
        }
      }
    }
  }
  text
}
