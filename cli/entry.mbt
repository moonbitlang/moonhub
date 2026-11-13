///|
/// Run the collaboration client with the same diagnostics and exit codes on
/// native and Wasm entry points. Unexpected failures never print credentials.
pub async fn execute(args : ArrayView[String]) -> Int32 {
  run(args) catch {
    Invalid(message) => {
      @stdio.stderr.write("moonhub: \{message}\n")
      2
    }
    InvalidResponse => {
      @stdio.stderr.write("moonhub: invalid API JSON response\n")
      1
    }
    TimedOut => {
      @stdio.stderr.write(
        "moonhub: API request timed out; check --server and network connectivity. Mutations are not retried automatically.\n",
      )
      1
    }
    Rejected(status, message) => {
      @stdio.stderr.write(
        "moonhub: HTTP \{status}: \{terminal_text(message)}\n",
      )
      match status {
        401 =>
          @stdio.stderr.write(
            "Token may be expired or revoked. Run auth setup --server SERVER, then auth login with a new token.\n",
          )
        403 =>
          @stdio.stderr.write(
            "Check the token's read/write/execute/merge permission and your repository role; auth setup explains permissions.\n",
          )
        404 =>
          @stdio.stderr.write(
            "Check --server, --repo OWNER/NAME and the resource number. Private resources may require additional repository access.\n",
          )
        409 =>
          @stdio.stderr.write(
            "Read the latest view/list --json, inspect the changes and retry with its version, edit_version or state_version.\n",
          )
        _ => ()
      }
      1
    }
    _ => {
      @stdio.stderr.write(
        "moonhub: CLI request failed; check --server connectivity and any input file paths/permissions. Run auth status --json to check authentication.\n",
      )
      1
    }
  }
}
