///|
pub let test_ssh_addresses : @repository.SshAddressConfig = {
  public_override: Some({ host: "git.example.com", port: 12222, }),
  internal: Some({ host: "ssh", port: 2222, }),
}
