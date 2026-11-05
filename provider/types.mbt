///|
pub(all) suberror ProviderError {
  InvalidConfiguration(String)
  TransportFailure
  Rejected(Int32)
  DockerFailure(Int32)
  CleanupFailure
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
  poll_ms : Int32
  allow_http : Bool
  memory : String
  cpus : String
  pids_limit : Int32
}

///|
priv struct AssignmentResult {
  code : Int32
  reported : Bool
}

///|
priv struct ClaimedAssignment {
  assignment : @protocol.Assignment
  attempt_token : String
}

///|
fn random_hex(byte_count : Int32) -> String raise ProviderError {
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

///|
pub(all) struct MacOptions {
  tart : String
  home : String
  prepare_timeout_ms : Int32
}

///|
priv struct WorkerBackend {
  os : String
  fresh_each_job : Bool
  initialize : async () -> Unit
  prepare : async (Options) -> Unit
  health : async () -> Unit
  execute : async (Options, @protocol.Assignment, String) -> Unit
  cleanup : async () -> Unit
}
