///|
async fn run_repository(
  action : String,
  matches : @argparse.Matches,
  options : @argparse.Matches,
  server : String,
  token : String,
  allow_http~ : Bool,
) -> Int32 {
  let explicit = if option(options, "repository") is Some(repo) {
    guard !(matches.sources.get("repo") is Some(Argv)) else {
      raise Invalid("use OWNER/NAME or --repo OWNER/NAME once")
    }
    Some(repo)
  } else {
    option(matches, "repo")
  }
  let create = action == "create"
  guard !create || explicit is Some(_) else {
    raise Invalid("repo create requires OWNER/NAME or --repo OWNER/NAME")
  }
  let repo = match explicit {
    Some(name) => parse_cli_repo(name, label="repository")
    None => discover_repo(server)
  }
  let path = "/repos/" + repo.path()
  let mut result = if create {
    let visibility = required(matches, "visibility")
    guard visibility == "private" || visibility == "public" else {
      raise Invalid("--visibility must be private or public")
    }
    request(
      server,
      token,
      "/repos",
      Some({ "owner": repo.owner, "name": repo.name, "visibility": visibility }),
      allow_http~,
    )
  } else {
    request(server, token, path, None, allow_http~)
  }
  if create {
    // Retain the last observed state if the polling deadline expires.
    ignore(
      @async.with_timeout_opt(30000, () => {
        while result is { "state": String("pending" | "running"), .. } {
          @async.sleep(1000)
          result = request(server, token, path, None, allow_http~)
        }
      }),
    )
  }
  guard result
    is {
      "state": String("ready" | "pending" | "running" | "failed" as state),
      ..
    } else {
    raise InvalidResponse
  }
  if matches.flags.get("json").unwrap_or(false) {
    println(result.stringify())
  } else {
    render_repository(result, server, repo, state, create)
  }
  if create && state == "failed" {
    1
  } else {
    0
  }
}

///|
// The next steps include server-supplied values and IPv6 bracket syntax.
fn shell_argument(value : String) -> String {
  "'" + value.replace_all(old="'", new="'\\''") + "'"
}

///|
fn render_repository(
  json : Json,
  server : String,
  repo : @domain.RepoId,
  state : String,
  create : Bool,
) -> Unit raise CliError {
  guard json
    is { "full_name": String(full_name), "visibility": String(visibility), .. } else {
    raise InvalidResponse
  }
  let name = terminal_text(full_name)
  let visibility = terminal_text(visibility)
  if create && state == "ready" {
    println("Created \{name} (\{visibility}).")
  } else {
    println("\{name}\t\{visibility}\t\{state}")
  }
  let branch = match json {
    { "default_branch": String(branch), .. } => Some(terminal_text(branch))
    _ => None
  }
  if branch is Some(branch) {
    println("Default branch: \{branch}")
  }
  let clone_url = match json {
    { "clone_url": String(url), .. } => Some(terminal_text(url))
    _ => None
  }
  match clone_url {
    Some(url) => println("Clone URL: \{url}")
    None =>
      println(
        "Clone URL unavailable: a site administrator must configure the SSH address.",
      )
  }
  match state {
    "ready" if create && clone_url is Some(url) => {
      let refspec = branch
        .map(branch => "HEAD:refs/heads/" + branch)
        .unwrap_or("HEAD")
      println(
        "Next:\n  git remote add origin \{shell_argument(url)}\n  git push -u origin \{shell_argument(refspec)}",
      )
    }
    "ready" => ()
    "failed" =>
      println(
        "Creation failed. Retry or discard it at \{server}/\{repo.owner}/-/repositories/\{repo.name}/status",
      )
    _ =>
      println(
        "Still provisioning. Check again with: moonhub repo view --repo \{name}",
      )
  }
}
