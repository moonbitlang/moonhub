///|
pub(all) suberror ProviderError {
  InvalidConfiguration(String)
  TransportFailure
  Rejected(Int)
  DockerFailure(Int)
  Stopped
}

///|
pub(all) struct Options {
  server : String
  runner_server : String
  runner_image : String
  docker : String
  docker_host : String
  network : String
  runner_host : String
  runner_host_ip : String
  workspace_root : String
  poll_ms : Int
  allow_http : Bool
  memory : String
  cpus : String
  pids_limit : Int
}

///|
priv struct AssignmentResult {
  code : Int
  reported : Bool
}

///|
priv struct ClaimedAssignment {
  assignment : @protocol.Assignment
  attempt_token : String
}

///|
fn random_hex(byte_count : Int) -> String raise ProviderError {
  guard @env.rand(byte_count) is Some(bytes) else {
    raise InvalidConfiguration("secure randomness unavailable")
  }
  let digits = "0123456789abcdef"
  let result = StringBuilder()
  for byte in bytes {
    result.write_char(digits.get_char(byte.to_int() / 16).unwrap())
    result.write_char(digits.get_char(byte.to_int() % 16).unwrap())
  }
  result.to_string()
}
