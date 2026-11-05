# Workflow entry compatibility

The first openseek acceptance target is the unmodified Tools SDK workflow at
`9e8b15a59b40b62b018e53b4b85a3bea971e1acf`. Its original YAML is retained in
`pipeline/workflow/fixtures/openseek-tools-sdk.yml`.

## Runner selectors

Single environment selectors `ubuntu-22.04`, `ubuntu-24.04`, `ubuntu-latest` and
`windows-2022` normalize to `self-hosted`, their OS, `x64`, and the **unchanged
exact environment label**. All labels must match a registered provider. A generic
Linux provider or an ARM64 provider does not match an Ubuntu x64 request.
Existing explicit self-hosted label arrays retain their behavior.

Environment labels are operator-declared image capabilities. Register them only
when the configured runner image supplies that userspace and toolchain contract.
The runner independently verifies Ubuntu ID, explicit VERSION_ID and CPU
architecture before executing a requested Ubuntu environment. `ubuntu-latest`
requires an explicit provider alias policy; it is not silently redirected when
GitHub changes its hosted-image mapping. This does not claim the entire GitHub
hosted software inventory. Windows Server 2022 retains its existing provider
checks. Other hosted selectors still fail validation.

`deploy/ubuntu/Dockerfile` supplies real Ubuntu 24.04 userspace, fixed Node
runtimes and a native runner built for the same architecture:

```sh
docker build --platform linux/amd64 -f deploy/ubuntu/Dockerfile \
  --target runner \
  -t moonhub-runner:ubuntu-24.04 .
```

Configure that image and the labels `self-hosted,linux,x64,ubuntu-24.04` together.
Existing Debian providers should not acquire the Ubuntu capability label.

## Branch and path filters

Push and pull-request events accept `branches`/`branches-ignore` and
`paths`/`paths-ignore`. A branch filter and a path filter must both match.
PR branch patterns match the target branch. Pattern lists retain order: matching
negative patterns exclude a previous match and later positive patterns can
include it again. Include and ignore forms cannot coexist for one dimension;
include lists require at least one positive pattern.

The bounded, non-backtracking matcher supports `*`, `**`, recursive `**/`,
escaped literals, alphanumeric classes/ranges, and the preceding-character
`?`/`+` quantifiers. Matching is case-sensitive and covers the entire ref/path.
Each list has at most 64 patterns, each pattern at most 256 characters.

Existing-branch pushes compare the captured old and new commit trees, including
force pushes. PRs compare the revision's merge base and source head, so unrelated
target-only edits do not trigger a workflow. Deletions participate in matching;
renames contribute both old and new paths. Diffs use NUL-delimited names rather
than quoted patch text, with a 10-second, 2-MiB, 10,000-path bound. Empty diffs do
not match path-filtered workflows. If a diff is unavailable, times out or exceeds
limits or the 8-million-state aggregate matching budget, run conservatively. Newly created branches lack a reliable before SHA
in the current receive contract and therefore also run conservatively. Merge
receipts use the pinned merge commit's first parent.

Repository-required MR checks remain authoritative and run even when an automatic
workflow filter does not match. This preserves the existing merge gate rather
than allowing changed YAML to bypass repository policy. Manual dispatch ignores
automatic branch/path filters and still requires `workflow_dispatch`.

## Read-only contents permissions

Workflow/job `permissions` accepts only `{contents: read}`, `{contents: none}` or
`{}`. Job declarations replace workflow declarations. Omitted permissions retain
the historical read-only source access; missing saved fields decode to that
legacy default. Other permission scopes and `read-all`/`write-all` remain rejected.

The effective flag is saved in the immutable job definition and assignment.
`none` denies both authenticated source endpoints even for a live attempt,
disables automatic source fetching, and removes the checkout placeholder token
from the runtime context. An explicit checkout then fails rather than receiving
source. `read` remains limited to the pinned run snapshot and does not issue a
GitHub/MoonHub API token, grant write access or change repository-secret policy.

## Acceptance

Offline tests cover the verbatim YAML, filtering (including rename/deletion and
PR merge-base behavior), provider matching, image checks, permission inheritance,
legacy JSON and source authorization. The opt-in smoke executes the unchanged
workflow's eight steps and cleanup through the native runner and its HTTP
protocol, using downloaded upstream checkout:

```sh
git init --bare /tmp/openseek.git
git --git-dir /tmp/openseek.git fetch --depth=1 --no-tags \
  https://github.com/moonbitlang/openseek.git \
  9e8b15a59b40b62b018e53b4b85a3bea971e1acf
git --git-dir /tmp/openseek.git update-ref refs/heads/main FETCH_HEAD
docker build --platform linux/amd64 -f deploy/ubuntu/Dockerfile \
  --target tools-sdk-check -t moonhub-tools-sdk:check .
docker run --rm --platform linux/amd64 \
  --mount type=bind,src="$PWD",dst=/work,readonly \
  --mount type=bind,src=/tmp/openseek.git,dst=/source.git,readonly \
  moonhub-tools-sdk:check /source.git
```

The smoke requires network access and executes third-party action/install code.
It verifies Ubuntu/x64, checks that the upstream YAML exactly matches the parser
fixture, serves a pinned Git bundle through a test HTTP endpoint, and starts the
real native runner. The job installs its own MoonBit version and runs check,
native/wasm tests, format and package. The smoke also verifies native step states,
log sequencing, the final report and checkout post cleanup. Its test endpoint
complements coordinator authorization/filter tests; it is not a production deployment.

Verified acceptance on 2026-11-04: the native runner reported all eight original
steps successful on Ubuntu 24.04 x64. Upstream checkout v5 resolved to
`fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09`; the unmodified install step selected
MoonBit `0.10.18+1fd8467c3-nightly`. Native and wasm suites each passed 46 tests,
format and package succeeded, and checkout post removed its temporary extraheader.
