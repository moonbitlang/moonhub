///|
fn valid_vm_image(image : String) -> Bool {
  if image.strip_prefix("local:") is Some(name) {
    return !["", ".", ".."].contains(name.to_owned()) &&
      name.length() <= 100 &&
      !name.has_prefix("-") &&
      !name.has_prefix("moonhub-slot-") &&
      name
      .iter()
      .all(c => {
        c.is_ascii_alphabetic() ||
        c.is_ascii_digit() ||
        c == '-' ||
        c == '_' ||
        c == '.'
      })
  }
  // Resolve mutable remote tags during image preparation, never when claiming work.
  image.length() <= 256 &&
  image.split_once("@sha256:") is Some((repository, digest)) &&
  !repository.is_empty() &&
  !repository.has_prefix("-") &&
  repository
  .iter()
  .all(c => {
    c.is_ascii_alphabetic() ||
    c.is_ascii_digit() ||
    c == '/' ||
    c == '.' ||
    c == '-' ||
    c == '_'
  }) &&
  digest.length() == 64 &&
  digest.iter().all(c => c.is_ascii_digit() || (c >= 'a' && c <= 'f'))
}

///|
async fn tart_control(
  macos : MacOptions,
  args : Array[String],
  timeout~ : Int32 = 15000,
) -> String {
  @async.with_timeout(timeout, () => {
    let (code, output) = @process.collect_output_merged(
      macos.tart,
      args,
      inherit_env=false,
      extra_env={
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": macos.home,
        "TART_HOME": macos.home,
      },
    )
    guard code == 0 else {
      raise InvalidConfiguration(
        "Mac VM backend command failed; inspect the dedicated backend log.",
      )
    }
    let text = output.text()
    guard @utf8.encode(text).length() <= 65536 else {
      raise InvalidConfiguration("Mac VM backend response exceeds limits")
    }
    text
  })
}

///|
fn vm_names(json : String) -> Array[String] raise {
  let rows : Array[Json] = @json.from_json(@json.parse(json)) catch {
    _ => raise InvalidConfiguration("Tart inventory is not a JSON array")
  }
  let names : Array[String] = []
  for row in rows {
    guard row is Object(fields) && fields.get("Name") is Some(String(name)) else {
      raise InvalidConfiguration("Invalid VM inventory")
    }
    if name.has_prefix("moonhub-slot-") {
      guard name.length() == 45 &&
        name[13:].iter().all(c => c.is_ascii_digit() || (c >= 'a' && c <= 'f')) else {
        raise InvalidConfiguration("Invalid managed VM identity")
      }
      names.push(name)
    }
  }
  names
}

///|
async fn remove_vm(macos : MacOptions, name : String) -> Unit {
  let names = vm_names(
    tart_control(macos, ["list", "--source", "local", "--format", "json"]),
  )
  if !names.contains(name) {
    return
  }
  // stop may report an already stopped VM. Deletion and a fresh inventory are
  // the authoritative cleanup acknowledgement, never a swallowed stop error.
  ignore(tart_control(macos, ["stop", name, "--timeout", "0"])) catch {
    _ => ()
  }
  for retry = 0; retry < 100; retry = retry + 1 {
    let info = @json.parse(
      tart_control(macos, ["get", name, "--format", "json"]),
    )
    if info is Object(fields) && fields.get("Running") is Some(False) {
      break
    }
    @async.sleep(100)
  }
  ignore(tart_control(macos, ["delete", name]))
  guard !vm_names(
    tart_control(macos, ["list", "--source", "local", "--format", "json"]),
  ).contains(name) else {
    raise CleanupFailure
  }
}

///|
fn validate_vm_template(text : String) -> Unit raise {
  let template = @json.parse(text)
  guard template is Object(fields) &&
    fields.get("OS") is Some(String("darwin")) &&
    fields.get("State") is Some(String("stopped")) else {
    raise InvalidConfiguration(
      "Use a stopped macOS template, never a running or suspended guest",
    )
  }
}

///|
async fn run_tart_worker(
  base : Options,
  token : String,
  macos : MacOptions,
) -> Unit {
  guard @platform.macos() &&
    macos.home.has_prefix("/") &&
    !macos.tart.is_empty() &&
    macos.prepare_timeout_ms >= 10000 &&
    macos.prepare_timeout_ms <= 900000 else {
    raise InvalidConfiguration(
      "Use a dedicated absolute Tart home on an Apple Silicon Mac",
    )
  }
  @platform.private_directory(macos.home)
  @fs.chmod(macos.home, 0o700)
  let lock = @fs.open(
    macos.home + "/worker.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  @async.with_timeout(1000, () => lock.lock(Exclusive)) catch {
    _ => raise InvalidConfiguration("Cannot acquire exclusive Tart home lock")
  }
  let slot = Ref("")
  let started = Ref(0L)
  let running : Ref[@async.Task[Int32]?] = Ref(None)
  @async.with_task_group(tasks => {
    async fn cleanup() -> Unit {
      if slot.val.is_empty() {
        return
      }
      let before = @env.now().reinterpret_as_int64()
      // Join the actual VM process before deleting its directory: a shutdown
      // finalizer can otherwise recreate NVRAM/config after `tart delete`.
      ignore(tart_control(macos, ["stop", slot.val, "--timeout", "0"])) catch {
        _ => ()
      }
      if running.val is Some(task) {
        @async.with_timeout(15000, () => {
          ignore(task.wait()) catch {
            // Process::run waits for native termination before propagating
            // cancellation. A cancelled joined task is still safe to delete.
            @async.WaitedTaskAlreadyCancelled => ()
            err => raise err
          }
        }) catch {
          _ => raise CleanupFailure
        }
      }
      remove_vm(macos, slot.val) catch {
        _ => raise CleanupFailure
      }
      let directory = macos.home + "/vms/" + slot.val
      if @fs.exists(directory) {
        guard @fs.kind(directory, follow_symlink=false) is Directory else {
          raise CleanupFailure
        }
        @fs.rmdir(directory, recursive=true)
      }
      guard !@fs.exists(directory) else { raise CleanupFailure }
      slot.val = ""
      running.val = None
      @stdio.stderr.write(
        "runner: macOS VM cleanup_ms=" +
        (@env.now().reinterpret_as_int64() - before).to_string() +
        "\n",
      )
    }
    async fn health() -> Unit {
      guard running.val is Some(task) && task.try_wait() is None else {
        raise InvalidConfiguration("Prepared Mac VM stopped")
      }
      let result = @json.parse(
        tart_control(macos, [
          "exec",
          slot.val,
          "/usr/bin/sudo",
          "-n",
          "/usr/local/libexec/moonhub-macos-guest",
          "health",
        ]),
      )
      guard result is Object(fields) &&
        fields.get("version") is Some(Number(1, ..)) &&
        fields.get("os") is Some(String("macos")) &&
        fields.get("arch") is Some(String("arm64")) &&
        fields.get("clean") is Some(True) &&
        fields.get("runtime") is Some(Number(1, ..)) else {
        raise InvalidConfiguration(
          "Mac guest is not a clean execution environment",
        )
      }
    }
    run_backend_worker(base, token, {
      os: "macos",
      fresh_each_job: true,
      prepare_claim: _ => (),
      initialize: () => {
        guard tart_control(macos, ["--version"]).trim() == "2.41.1" else {
          raise InvalidConfiguration("Use verified Tart 2.41.1")
        }
        let names = vm_names(
          tart_control(macos, ["list", "--source", "local", "--format", "json"]),
        )
        for name in names {
          remove_vm(macos, name)
        }
        // Inventory can omit incomplete/corrupt VM directories. Refuse reuse
        // instead of silently overlooking a possibly live orphan.
        let directory = macos.home + "/vms"
        if @fs.exists(directory) {
          guard !@fs.readdir(directory).any(name => {
            name.has_prefix("moonhub-slot-")
          }) else {
            raise CleanupFailure
          }
        }
      },
      prepare: current => {
        cleanup()
        guard valid_vm_image(current.runner_image) else {
          raise InvalidConfiguration(
            "Use a pinned OCI VM digest or an operator-owned local:template",
          )
        }
        let begin = @env.now().reinterpret_as_int64()
        // Download the pinned image before the bounded boot deadline; a cache
        // miss is preparation, never standby or an already leased attempt.
        let image = if current.runner_image.strip_prefix("local:") is Some(name) {
          let name = name.to_owned()
          validate_vm_template(
            tart_control(macos, ["get", name, "--format", "json"]),
          )
          name
        } else {
          ignore(
            tart_control(macos, ["pull", current.runner_image], timeout=900000),
          )
          current.runner_image
        }
        slot.val = "moonhub-slot-" + random_hex(16)
        ignore(tart_control(macos, ["clone", image, slot.val], timeout=120000))
        // `tart get` accepts local VMs only. Inspect the clone for OCI sources,
        // while local templates were also checked before copying live disks.
        validate_vm_template(
          tart_control(macos, ["get", slot.val, "--format", "json"]),
        )
        ignore(
          tart_control(macos, [
            "set",
            slot.val,
            "--cpu",
            current.cpus,
            "--memory",
            current.memory.strip_suffix("m").unwrap().to_owned(),
          ]),
        )
        let log = @process.redirect_to_file(
          macos.home + "/vm.log",
          permission=0o600,
        )
        let input = @process.redirect_from_file("/dev/null")
        let name = slot.val
        running.val = Some(
          tasks.spawn(no_wait=true, () => {
            @process.run(
              macos.tart,
              [
                "run", name, "--no-graphics", "--no-audio", "--no-clipboard", "--no-usb-accessories",
              ],
              inherit_env=false,
              extra_env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": macos.home,
                "TART_HOME": macos.home,
              },
              stdin=input,
              stdout=log,
              stderr=log,
              cancel_handler=@process.hard_cancel(),
            ) catch {
              _ => 125
            }
          }),
        )
        @async.with_timeout(macos.prepare_timeout_ms, () => {
          for ;; {
            guard running.val is Some(task) && task.try_wait() is None else {
              raise InvalidConfiguration("Mac VM exited during preparation")
            }
            if (try {
                health()
                true
              } catch {
                _ => false
              }) {
              break
            }
            @async.sleep(500)
          }
        })
        started.val = @env.now().reinterpret_as_int64()
        @stdio.stderr.write(
          "runner: macOS VM prepared_ms=" +
          (started.val - begin).to_string() +
          "\n",
        )
      },
      health,
      execute: (current, assignment, credential) => {
        guard @platform.job_os(assignment.job.runs_on) == "macos" &&
          assignment.has_valid_numbers() else {
          raise InvalidConfiguration("Invalid Mac assignment")
        }
        let payload : Json = {
          "version": 1,
          "server": current.runner_server,
          "allow_http": current.allow_http,
          "assignment": ToJson::to_json(assignment),
          "token": credential,
        }
        let (stdin, writer) = @process.write_to_process()
        defer writer.close()
        let (stdout, output) = @process.read_from_process()
        defer stdout.close()
        let (stderr, diagnostic) = @process.read_from_process()
        defer stderr.close()
        let name = slot.val
        let begin = @env.now().reinterpret_as_int64()
        defer @async.protect_from_cancel(cleanup)
        @async.with_timeout(assignment.job.timeout_minutes * 60000 + 30000, () => {
          @async.with_task_group(group => {
            let child = @process.spawn(
              group,
              macos.tart,
              [
                "exec", "-i", name, "/usr/bin/sudo", "-n", "/usr/local/libexec/moonhub-macos-guest",
                "execute",
              ],
              inherit_env=false,
              extra_env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": macos.home,
                "TART_HOME": macos.home,
              },
              stdin~,
              stdout=output,
              stderr=diagnostic,
              cancel_handler=@process.hard_cancel(),
            )
            let result = group.spawn(() => read_bounded(stdout, 65536))
            let errors = group.spawn(() => read_bounded(stderr, 8192))
            writer.write(payload.stringify() + "\n")
            writer.close()
            let code = child.wait()
            let text = result.wait()
            let diagnostic_text = errors.wait()
            ignore(diagnostic_text)
            let report = @json.parse(text) catch {
              _ =>
                raise InvalidConfiguration(
                  "Mac guest returned no valid completion report (exit " +
                  code.to_string() +
                  ")",
                )
            }
            if report is Object(details) &&
              details.get("error") is Some(String(reason)) &&
              [
                "isolation", "workspace", "launcher", "assignment", "runtime", "identity",
                "payload", "spawn",
              ].contains(reason) {
              raise InvalidConfiguration(
                "Mac guest failed before completion: " + reason,
              )
            }
            guard (code == 0 || code == 1) &&
              report is Object(fields) &&
              fields.get("reported") is Some(True) else {
              raise InvalidConfiguration("Mac guest did not report completion")
            }
          })
        })
        @stdio.stderr.write(
          "runner: macOS VM attempt_ms=" +
          (@env.now().reinterpret_as_int64() - begin).to_string() +
          " standby_age_ms=" +
          (begin - started.val).to_string() +
          "\n",
        )
      },
      cleanup,
    })
  })
}
