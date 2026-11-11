///|
// Validate untrusted assignments independently of the workflow parser.
fn valid_moonbit_version(version : String) -> Bool {
  ["latest", "nightly", "pre-release"].contains(version) ||
  (
    version.length() <= 128 &&
    version.get_char(0) is Some(first) &&
    first.is_ascii_digit() &&
    !version.contains("..") &&
    version
    .iter()
    .all(ch => {
      ch.is_ascii_alphabetic() ||
      ch.is_ascii_digit() ||
      ch == '.' ||
      ch == '+' ||
      ch == '-'
    }) &&
    version.get_char(version.length() - 1) is Some(last) &&
    (last.is_ascii_alphabetic() || last.is_ascii_digit())
  )
}

///|
async fn fetch_moonbit_installer() -> Bytes {
  let client = @http.Client("https://cli.moonbitlang.com")
  defer client.close()
  let response = client.get(
    if @platform.windows() {
      "/install/powershell.ps1"
    } else {
      "/install/unix.sh"
    },
  )
  guard response.code == 200 else {
    raise InvalidConfiguration("MoonBit installer download failed")
  }
  let bytes : Array[Byte] = []
  while client.read_some(max_len=8192) is Some(chunk) {
    guard bytes.length() + chunk.length() <= 262144 else {
      raise InvalidConfiguration("MoonBit installer exceeds 256 KiB")
    }
    for byte in chunk {
      bytes.push(byte)
    }
  }
  guard !bytes.is_empty() else {
    raise InvalidConfiguration("MoonBit installer is empty")
  }
  Bytes::from_array(bytes)
}

///|
async fn Runtime::setup_moonbit(
  self : Runtime,
  step : @protocol.StepPlan,
  index : Int32,
  scratch : String,
  installer : async () -> Bytes,
  timeout_ms : Int32,
) -> Int32 {
  self.upload(
    step.id,
    "stdout",
    "Installing MoonBit " + step.moonbit_version + "\n",
  )
  let bytes = installer()
  self.check_live()
  let installer_path = scratch +
    "/moonbit-installer-\{index}" +
    (if @platform.windows() { ".ps1" } else { ".sh" })
  @fs.write_file(installer_path, bytes, create_mode=CreateNew, permission=0o600)
  // Never install over the default MOON_HOME's symlinks into /opt/moon.
  let toolchain = self.job_home + "/moonbit-\{index}"
  @fs.mkdir(toolchain, permission=0o700)
  let script = scratch +
    "/setup-moonbit-\{index}" +
    (if @platform.windows() { ".ps1" } else { ".sh" })
  @fs.write_file(
    script,
    if @platform.windows() {
      (
        #|$env:MOONBIT_INSTALL_VERSION = $env:MOONHUB_MOONBIT_VERSION
        #|& $env:MOONHUB_MOONBIT_INSTALLER
        #|if (-not $?) { exit 1 }
        #|foreach ($file in @('bin/moon.exe', 'bin/moonc.exe', 'bin/moonrun.exe', 'lib/core')) {
        #|  if (-not (Test-Path ($env:MOON_HOME + '/' + $file))) { throw "MoonBit installation is incomplete" }
        #|}
        #|& ($env:MOON_HOME + '/bin/moon.exe') version --all
      )
    } else {
      (
        #|bash "$MOONHUB_MOONBIT_INSTALLER" "$MOONHUB_MOONBIT_VERSION"
        #|test -x "$MOON_HOME/bin/moon"
        #|test -x "$MOON_HOME/bin/moonc"
        #|test -x "$MOON_HOME/bin/moonrun"
        #|test -d "$MOON_HOME/lib/core"
        #|"$MOON_HOME/bin/moon" version --all
      )
    },
    create_mode=CreateNew,
    permission=0o600,
  )
  let code = self.execute_script(
    {
      ..step,
      shell: if @platform.windows() {
        "pwsh"
      } else {
        "bash"
      },
      env: {
        "MOON_HOME": toolchain,
        "PATH": if @platform.windows() {
          toolchain +
          "/bin;C:/moonhub/bin;C:/moonhub/pwsh;C:/moonhub/git/cmd;C:/Windows/System32;C:/moonhub/git/usr/bin;" +
          @platform.environment()
          .get("PATH")
          .unwrap_or("C:/Windows/System32;C:/Windows")
        } else {
          toolchain + "/bin:/opt/moon/bin:/usr/local/bin:/usr/bin:/bin"
        },
        "MOONHUB_MOONBIT_VERSION": step.moonbit_version,
        "MOONHUB_MOONBIT_INSTALLER": installer_path,
      },
    },
    script,
    timeout_ms,
  )
  if code == 0 {
    // Preserve the image's registry settings in a writable job-local copy.
    let config = "/opt/moon/config.json"
    if @fs.exists(config) {
      @fs.write_file(
        toolchain + "/config.json",
        @fs.read_file(config).binary(),
        permission=0o600,
      )
    }
    self.moon_home = toolchain
  }
  code
}
