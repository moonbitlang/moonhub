# Openseek migration inventory

Reviewed on 2026-11-04 at openseek commit
`9e8b15a59b40b62b018e53b4b85a3bea971e1acf`, from `.github/workflows/`.
The compatibility target is to preserve existing GitHub Actions YAML where
possible and execute downloaded action code. Reimplementing each `uses` entry
as a MoonHub built-in is not the approach.

## Inventory

Thirteen workflow files were inspected: `ci.yml`, `cli-release.yml`,
`desktop.yml`, `desktop-release.yml`, `editor.yml`, `tools-sdk.yml`,
`copilot-setup-steps.yml`, and the six `publish-*` workflows for editor,
inspect, openseek, openseek-tools, openseek-protocol and openseek-tui.

| Area | Existing usage | Current state / remaining work |
| --- | --- | --- |
| Action loading | checkout v5/v6, setup-node v4, setup-java v4, setup-android v3, Gradle setup v4, MSVC setup v1 | Generic public download, metadata, Node 20/24 and composite execution implemented. Individual platform/toolchain compatibility still needs acceptance. |
| Source checkout | Pinned source, release history/refs | Real upstream checkout supported with a pinned single-commit Git source. Full history, tags, alternate repositories, LFS and submodules need a fuller authenticated Git transport. |
| Step chaining | `GITHUB_ENV`, `GITHUB_PATH`, outputs and conditional steps | Implemented runtime file commands, public templates, step conditions and continue-on-error. |
| Scheduling | Static DAG, matrix include/exclude, fail-fast, concurrency/cancellation | Static DAG already exists. Matrix expansion, strategy policy and workflow concurrency semantics remain. |
| Runners | Ubuntu, macOS and Windows; bash/pwsh | Linux and Windows executors exist. Selected Ubuntu/Windows environment labels now require explicit matching provider capabilities; Ubuntu version/architecture are verified. See workflow-entry.md for the real Ubuntu 24.04 image. macOS and other hosted-image contracts remain separate work. |
| Triggering | Branch/path filters, pull-request events, dispatch inputs, schedule | Push/PR branch/path globs, ordered exclusions and ignore lists are supported with snapshot-based diffs. Dispatch inputs and cron scheduling remain. |
| Cache | cache v4, cache/restore, cache/save; setup-tool caching | Downloaded JS can be loaded, but the GitHub-compatible cache runtime service, tokens, scoped keys, archive storage and retention remain. |
| Artifacts | upload-artifact v4 and cross-job download-artifact v4 | Requires the artifact runtime service, scoped short-lived credentials, upload/download, named artifacts and lifecycle. Downloading the action alone does not provide this service. |
| Release identities | `permissions`, `github.token`, gh CLI/API, AWS configure-credentials v5 with OIDC | Repository secret delivery exists. GitHub API compatibility, scoped workflow tokens and OIDC issuer/audience/subject policy remain. Do not forward provider credentials. |
| Data contexts | `matrix`, `needs` outputs, `vars`, dispatch/event payloads | Current runtime supports public github/runner/env/steps and composite inputs. Server snapshots and contracts for these additional contexts remain. |
| Permissions/container capabilities | Permissions declarations, OS/toolchain/container requirements | contents read/none is enforced on both source transports; Ubuntu selectors use exact provider/image capabilities. Other scopes and container features still fail validation. |

## Acceptance boundary

This change makes downloaded JavaScript/composite actions executable and provides
cross-step execution primitives. It does **not** make all thirteen openseek files
runnable unchanged. They continue to fail validation at unsupported declarations,
rather than silently losing semantics or reporting a false green migration.

Further service work should retain upstream cache/artifact/OIDC action code and
provide the protocols and authorization those actions need. Changing openseek's
release workflows to use shell workarounds or hard-coded replacement actions would
not meet the compatibility target.

The first unchanged workflow acceptance target is Tools SDK; its fixture, trigger
contract, Ubuntu image and native-runner smoke are documented in
[workflow entry compatibility](workflow-entry.md).
