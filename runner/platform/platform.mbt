///|
#cfg(platform="windows")
pub fn windows() -> Bool {
  true
}

///|
#cfg(not(platform="windows"))
pub fn windows() -> Bool {
  false
}

///|
pub extern "C" fn macos() -> Bool = "moonhub_platform_macos"

///|
pub extern "C" fn windows_build() -> Int32 = "moonhub_platform_windows_build"

///|
extern "C" fn architecture_code() -> Int32 = "moonhub_platform_architecture"

///|
pub fn architecture() -> String {
  match architecture_code() {
    1 => "x64"
    2 => "arm64"
    _ => "unknown"
  }
}

///|
pub fn os() -> String {
  if windows() {
    "windows"
  } else if macos() {
    "macos"
  } else {
    "linux"
  }
}

///|
pub fn job_os(labels : Array[String]) -> String {
  if labels.contains("windows") {
    "windows"
  } else if labels.contains("macos") {
    "macos"
  } else {
    "linux"
  }
}

///|
// Only OS infrastructure is inherited. Job environments never inherit cloud,
// provider or controller credentials from the worker's environment.
pub fn environment() -> Map[String, String] {
  if !windows() {
    return { "PATH": "/usr/bin:/bin" }
  }
  let result : Map[String, String] = Map([])
  for key, value in @env.get_env_vars() {
    if [
        "path", "systemroot", "windir", "systemdrive", "comspec", "pathext", "temp",
        "tmp", "programfiles", "programfiles(x86)", "programw6432", "programdata",
        "commonprogramfiles", "commonprogramfiles(x86)", "commonprogramw6432",
      ].contains(key.to_lower()) {
      result[key.to_upper()] = value
    }
  }
  result
}

///|
pub fn path_key(path : String) -> String {
  if windows() {
    path
    .replace_all(old="\\", new="/")
    .strip_prefix("//?/")
    .unwrap_or(path.replace_all(old="\\", new="/"))
    .to_owned()
    .to_lower()
  } else {
    path
  }
}

///|
pub fn within(root : String, path : String) -> Bool {
  let root = path_key(root).trim_end(chars="/").to_owned()
  let path = path_key(path)
  path == root || path.has_prefix(root + "/")
}

///|
pub fn valid_relative(path : String) -> Bool {
  !path.is_empty() &&
  !path.has_prefix("/") &&
  !path.contains("\\") &&
  !path.contains(":") &&
  path
  .split("/")
  .all(part => {
    !part.is_empty() &&
    part != ".." &&
    part.iter().all(ch => ch.to_int() >= 32 && ch.to_int() != 127) &&
    (
      !windows() ||
      part == "." ||
      (
        !part.has_suffix(".") &&
        !part.has_suffix(" ") &&
        ![
          "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6",
          "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6",
          "lpt7", "lpt8", "lpt9",
        ].contains(part.split(".").next().unwrap_or("").to_owned().to_lower())
      )
    )
  })
}

///|
#borrow(path)
extern "C" fn protect_directory(
  path : String,
  length : Int32,
  readable : Int32,
) -> Int32 = "moonhub_platform_protect_directory"

///|
pub async fn private_directory(path : String, readable~ : Bool = false) -> Unit {
  @fs.mkdir(path, permission=0o700, allow_exist=true, recursive=true)
  guard @fs.kind(path, follow_symlink=false) is Directory else {
    raise PlatformError("Private state directory must not be a symlink")
  }
  if windows() &&
    protect_directory(path, path.length(), if readable { 1 } else { 0 }) != 0 {
    raise PlatformError("Could not protect Windows state directory")
  }
}

///|
pub suberror PlatformError {
  PlatformError(String)
}
