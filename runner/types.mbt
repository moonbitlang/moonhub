///|
pub(all) suberror RunnerError {
  InvalidConfiguration(String)
  TransportFailure
  Rejected(Int32)
  InvalidResponse
  Stopped(String)
}

///|
pub(all) struct Options {
  server : String
  workspace : String
  launcher : String
  allow_http : Bool
  unsafe_local : Bool
  heartbeat_ms : Int32
}

///|
fn parse_runner_int64(value : String) -> Int64 raise RunnerError {
  match @protocol.parse_decimal(value) {
    Some(value) => value
    None => raise InvalidResponse
  }
}

///|
pub struct Report {
  conclusion : String
  reported : Bool
  steps : Array[@protocol.StepState]
} derive(Debug, ToJson)

///|
priv struct Runtime {
  post : async (String, Json, Int64) -> (@protocol.LeaseState, Int64)
  execution_id : String
  assignment : @protocol.Assignment
  options : Options
  lock : @async.Mutex
  steps : Array[@protocol.StepState]
  groups : Array[Int32]
  mut sequence : Int64
  mut bytes : Int64
  mut lease_until : Int64
  mut deadline : Int64
  mut stopped : String
  mut reporting_until : Int64
}

///|
extern "C" fn monotonic_ms() -> Int64 = "moonhub_runner_monotonic"

///|
extern "C" fn prepare_agent(local_mode : Int32) -> Int32 = "moonhub_runner_prepare"

///|
extern "C" fn kill_group(pid : Int32) -> Unit = "moonhub_runner_kill_group"

///|
extern "C" fn kill_namespace() -> Unit = "moonhub_runner_kill_namespace"

///|
extern "C" fn reap_namespace() -> Int32 = "moonhub_runner_reap_namespace"

///|
fn execution_nonce() -> String {
  guard @env.rand(16) is Some(bytes) else {
    abort("secure randomness unavailable")
  }
  let digits = "0123456789abcdef"
  let result = StringBuilder()
  for byte in bytes {
    result.write_char(digits.get_char(byte.to_int() / 16).unwrap())
    result.write_char(digits.get_char(byte.to_int() % 16).unwrap())
  }
  result.to_string()
}
