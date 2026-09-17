///|
pub async fn mock_import_config(
  root : String,
  source : String,
) -> @repository.RepoImportConfig {
  let credentials = "\{root}/credentials"
  @fs.mkdir("\{credentials}/alice", recursive=true, permission=0o700)
  @fs.write_file(
    "\{credentials}/alice/id_ed25519",
    "fixture identity",
    permission=0o600,
  )
  @fs.write_file(
    "\{credentials}/alice/known_hosts",
    "fixture known host",
    permission=0o600,
  )
  @fs.write_file(
    "\{credentials}/alice/allowed_hosts",
    "source.example:22\n",
    permission=0o600,
  )
  let wrapper = "\{root}/fixture-ssh"
  @fs.write_file(
    wrapper,
    "#!/bin/sh\nexec git upload-pack '\{source}'\n",
    permission=0o700,
  )
  // Functional imports share the async executor with CPU-heavy authentication
  // tests. Deadline behavior has its own test with an explicit short timeout.
  { credentials_root: credentials, ssh_wrapper: wrapper, timeout_ms: 300000, }
}
