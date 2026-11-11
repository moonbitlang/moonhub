# Windows Server 2025 build environment

This slice supports a generic x64 Windows C++ environment, using the original
openseek Windows TUI job as its first acceptance sample. The scheduler and task
image do not identify repositories or replace upstream Actions with built-ins.
The pinned upstream revision is
62a6fba1dccf92c98d4b3c26f5dcf12a5788a8b5.

## Selectors and execution contract

A scalar windows-latest resolves to windows-2025 when the workflow is parsed
into its immutable run definition. Both request these exact capabilities:

    self-hosted, windows, x64, windows-2025

The original YAML remains in the run snapshot, so its requested alias and the
concrete saved labels can both be inspected. Reruns use the saved concrete
labels and do not resolve a later alias policy. Explicit self-hosted arrays
retain their existing all-labels matching behavior. A provider with only
windows/x64 or windows-2022 cannot claim a windows-2025 job. If no matching
provider exists, the job waits for matching capacity; it does not fall back.

Windows 2025 jobs use assignment v11 so an older executor rejects the new
environment contract rather than silently ignoring its OS verification.
The lease/report protocol stays v1, and other jobs retain their existing
assignment selection. Coordinator, provider and task runner must support v11
before enabling a windows-2025 provider. No database migration is needed.

Before readiness, the worker inspects the actual Docker daemon and task-image
OS/architecture/version, starts an unprivileged probe through the selected
isolation mode and verifies a prepared workspace volume's ACL. Supported pairs:

| Host | Task image | Isolation |
| --- | --- | --- |
| Server 2022 x64 | Server 2022 x64 | process |
| Server 2025 x64 | Server 2022 or 2025 x64 | process |
| Windows 11 x64 | Server 2022 x64 | Hyper-V, as previously supported |

The worker does not claim a Windows 11/Server 2025 combination or run a 2025
image on Server 2022. Unknown images and architectures fail preflight. Each
fixed-environment task runner also independently reads the task userland's
Windows build number and its own binary architecture before executing job code.
This distinction matters when a 2022 container shares a 2025 host kernel.

## Generic C++ task image

Build the runtime bundle on Windows using the production MoonBit pin:

    moon update
    node scripts/resolve-dependencies.cjs
    ./scripts/build-windows-runner.ps1
    docker build --isolation=process -f deploy/windows/Dockerfile.build -t moonhub:build-windows-2025 .tmp/windows-runner

The build host must run a compatible Server 2025 Windows Docker daemon.
Dockerfile.build uses a digest-pinned Microsoft .NET Framework 4.8.1 / Server
Core LTSC 2025 base, plus the normal MoonHub runtime bundle. The separate legacy
Dockerfile continues to build the existing Server 2022 runtime image.

build-tools.json records immutable Microsoft download URLs and SHA-256 values
for the bootstrapper and frozen channel. The build verifies both and checks
the bootstrapper's Microsoft Authenticode signature. Microsoft's installer
obtains and validates its own catalog and packages through the frozen channel;
the build does not claim an independent catalog checksum. It installs the explicit
C++ compiler component and Windows SDK 26100, accepts the documented success
codes 0/3010, and verifies the resulting product version, VsDevCmd and SDK.
The toolchain is Visual Studio Build Tools 2022 17.14.37906.3. Installation is
unattended under the image build; normal jobs still run as ContainerUser.
Operators are responsible for the applicable Microsoft software licensing terms.

The image includes no source checkout, project dependency or cloud credential.
Job setup Actions choose Node and MoonBit versions. The runtime supplies Node
20/24 for Action entrypoints, Git and PowerShell 7. Standard Program Files paths
are inherited as OS infrastructure for vswhere and other setup tools; job HOME,
USERPROFILE and AppData paths remain private to the execution workspace.
MSVC environment initialization is performed by the downloaded upstream Action,
using the ordinary GITHUB_ENV/GITHUB_PATH file-command implementation.
The base PATH keeps Windows System32 before Git's Unix tools so native tar
handles drive-letter archive paths. Git Bash remains available explicitly.

Register a provider whose matching task image actually supplies this environment
with labels self-hosted,windows,x64,windows-2025 and the intended repository grants.
Do not add that capability to an existing Server 2022 provider. The bundle and
image can be used by a dedicated PC provider or the existing disposable ASG
worker path; all prior container/workspace cleanup requirements still apply.
This change does not update a production provider or publish an image itself.

## Acceptance

Both upstream workflow files are retained verbatim in pipeline/workflow/fixtures:
openseek-ci-windows.yml and openseek-desktop-windows.yml. Parser tests cover their
original selectors, and scheduling tests verify exact provider matching and v11.

GitHub CI keeps the existing Server 2022 worker/container regressions and adds a
Server 2025 matrix instance. Both exercise native policy tests, process cleanup,
real containers and standalone provider installation. On 2025, the original
2022 image tests also exercise the supported host/image combination.

The 2025 instance builds the generic C++ image, fetches the pinned openseek
commit into a single-commit bare repository and executes:

    node scripts/openseek-windows-smoke.mjs .tmp/openseek-source.git

The source bytes are checked against the verbatim fixture. The native runner
executes the original tui-windows job's six steps unchanged: downloaded checkout
v5, downloaded msvc-dev-cmd v1, the repository's fixed MoonBit install script,
version output, registry update, and native check/test of the discovered TUI
packages. A local authenticated HTTP endpoint supplies the pinned Git bundle
and disposable execution-bound runtime credentials. It checks log ordering,
credential masking, native step/final status and upstream checkout post cleanup.
The actual job runs as ContainerUser in its own disposable volume, without host
source mounts or production credentials. The test closes its endpoint and removes
only its own named container, workspace and temporary firewall rule.

The CI acceptance requires network access and executes upstream Action/toolchain
code. Passing YAML parsing or a mocked process call is not sufficient acceptance.
The normal Windows lifecycle tests additionally cover cancellation, cleanup before
ready, stale work reconciliation and reuse of a clean worker.

The Desktop acceptance uses the same generic image and the original
desktop-windows.yml at the same pinned revision. Its workflow owns Node 22,
Proton/CEF installation, caches, packaging, DLL search paths, background-job tests
and Artifact upload. The acceptance does not alter those commands or replace
upstream Actions.

The Windows 2025 CI instance also builds the native Desktop HTTP test host before
reclaiming the host compiler. The opt-in test serves the production coordinator,
runner, Cache v2, Artifact v4 and Block Blob routes from a disposable SQLite
database and private artifact directory. A local adapter supplies only the pinned
Git bundle; no production service or credential is used. The original Desktop job
runs as ContainerUser in a fresh volume. A second job in another fresh volume
must restore both caches and download the packaged artifact, including runtime
DLLs and the hidden MoonBit seed receipt. Both task reports and checkout post
cleanup must succeed before the test removes its resources.

Run the same acceptance on a dedicated Windows build host after building the
image and preparing the single-commit source repository above:

    moon test --build-only --strip -j 1 web/views/pipelines/desktop_windows_wbtest.mbt
    $env:MOONHUB_DESKTOP_WINDOWS_SMOKE = '1'
    $env:MOONHUB_OPENSEEK_SOURCE = "$pwd/.tmp/openseek-source.git"
    node scripts/run-native-test.cjs _build/native/debug/test/web/views/pipelines/pipelines.whitebox_test.exe desktop_windows_wbtest.mbt

The wrapper checks the test result record as well as the process exit code.
Generated MoonBit test executables can exit zero after reporting a failed test.

This test verifies CI packaging and background-job behavior. It does not establish
interactive GUI support, signing, publishing or production runner rollout. Any
missing operating-system capability must be supplied generically; a workflow
must not acquire a repository-specific bypass.
