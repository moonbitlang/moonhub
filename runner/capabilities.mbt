///|
fn capability_request_source(capability : String) -> String {
  // This file carries an untrusted scheduling hint, never a credential or an
  // authorization proof. Fixed content and bounded reads avoid log heuristics.
  (
    #|#!/bin/sh
    #|capability='CAPABILITY'
    #|case "$1" in --version|--help|-h) echo 'moonhub: command unavailable in this execution profile' >&2; exit 127 ;; esac
    #|if [ "$capability" = docker ]; then
    #|  for argument in "$@"; do case "$argument" in -H|--host|--host=*|-H*|--context|--context=*|-c) exit 127 ;; esac; done
    #|fi
    #|if [ "$capability" = docker ] && [ -n "${DOCKER_HOST:-}${DOCKER_CONTEXT:-}" ]; then
    #|  echo 'moonhub: a Docker client for the requested remote endpoint is unavailable' >&2
    #|  exit 127
    #|fi
    #|if [ "$capability" = container-root ]; then
    #|  for argument in "$@"; do
    #|    case "$argument" in -*) continue ;; sysctl|/sbin/sysctl|/usr/sbin/sysctl) capability=host-kernel ;; esac
    #|    break
    #|  done
    #|fi
    #|request="$(dirname -- "$0")/request"
    #|printf '%s\n' "$capability" > "$request.$$"
    #|mv -f -- "$request.$$" "$request"
    #|printf '%s\n' "moonhub: this execution environment lacks $capability capability" >&2
    #|exit 125
  ).replace_all(old="CAPABILITY", new=capability)
}

///|
async fn prepare_capability_probes(directory : String) -> Unit {
  @fs.mkdir(directory, permission=0o700)
  for (name, capability) in [("docker", "docker"), ("sudo", "container-root")] {
    let file = directory + "/" + name
    @fs.write_file(
      file,
      capability_request_source(capability),
      permission=0o700,
    )
    @fs.chmod(file, 0o700)
  }
}

///|
#borrow(path)
extern "C" fn capability_read(path : Bytes) -> Int32 = "moonhub_runner_capability_read"

///|
fn Runtime::capture_capability(self : Runtime) -> Unit raise {
  guard !self.capability_dir.is_empty() else { return }
  match
    capability_read(@utf8.encode(self.capability_dir + "/request\u{0000}")) {
    0 => ()
    1 => self.missing_capability = "docker"
    2 => self.missing_capability = "container-root"
    3 => self.missing_capability = "host-kernel"
    _ => raise InvalidResponse
  }
}
