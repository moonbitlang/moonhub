# Repository configuration variables

Repository variables are readable, non-secret string settings exposed through
`${{ vars.NAME }}`. Use them for values such as `OPENSEEK_S3_BUCKET`,
`OPENSEEK_S3_REGION`, and `OPENSEEK_RELEASE_AWS_ROLE_ARN`. Credentials belong in
repository secrets; parameters selected for one manual run belong in dispatch
inputs. Variables do not automatically become process environment variables and
they are not masked in logs.

## Management and permissions

Repository owners and admins can create, edit and delete variables in repository
settings. Anyone with repository read access can read the values. This includes
public visibility for public repositories: never put passwords or access tokens
in variables. Authorized MR checks can consume variables, unlike secrets.

Names use ASCII letters, digits and underscores, cannot start with a digit, and
are at most 100 characters. Names and expression lookup are case-insensitive;
management responses store names in uppercase. Reserved `GITHUB_`, `RUNNER_` and
`MOONHUB_` prefixes and prototype-related identifiers are rejected.

Values may be empty strings and must contain no NUL. Each value is limited to
48 KiB of UTF-8, with at most 500 variables per repository. MoonHub additionally
bounds the complete encoded name/value JSON map to 256 KiB at write time so every
accepted configuration can be captured and delivered without truncation.
JSON escaping and names count toward that total. If a write exceeds a limit,
the entire operation is rejected; no variables are silently omitted.

The CLI accepts an exact UTF-8 file rather than a value in command arguments:

```sh
moonhub variable list --repo owner/repository --json
moonhub variable set OPENSEEK_S3_REGION --repo owner/repository \
  --body-file /absolute/path/region.txt --version 0
moonhub variable set OPENSEEK_S3_REGION --repo owner/repository \
  --body-file /absolute/path/new-region.txt --version CURRENT_VERSION
moonhub variable delete OPENSEEK_S3_REGION --repo owner/repository \
  --version CURRENT_VERSION
```

Version `0` creates a name. Updates and deletes require the current decimal
version from the list response. Recreating a deleted name receives a new version;
a stale edit cannot overwrite that replacement. Audit records include the name
and operation, not the value.

The JSON API is relative to `/-/api/v1`:

- `GET /repos/:owner/:repo/variables` returns names, values and versions.
- `POST /repos/:owner/:repo/variables/:name` accepts string `value` and `version`.
- `POST /repos/:owner/:repo/variables/:name/delete` accepts string `version`.

A read token can list accessible repository variables. Mutations require a write
token plus repository owner/admin access. Browser mutations retain CSRF and
cross-site validation. Responses use private/no-store headers. MCP provides `moonhub_list_variables`, `moonhub_set_variable` and
`moonhub_delete_variable` through its authenticated tool interface.

## Workflow execution

```yaml
on: workflow_dispatch
concurrency:
  group: publish-${{ vars.OPENSEEK_S3_REGION }}
jobs:
  publish:
    if: vars.PUBLISH_ENABLED == 'true'
    runs-on: ubuntu-24.04
    permissions: {contents: read, id-token: write}
    env:
      REGION: ${{ vars.OPENSEEK_S3_REGION }}
    steps:
      - uses: aws-actions/configure-aws-credentials@v5
        with:
          aws-region: ${{ vars.OPENSEEK_S3_REGION }}
          role-to-assume: ${{ vars.OPENSEEK_RELEASE_AWS_ROLE_ARN }}
      - run: printf '%s\n' "$REGION"
```

Variables work in workflow/job/step `env`, Action `with`, step `run` and conditions,
job conditions, workflow concurrency, and declared job outputs. Composite Actions
and JavaScript pre/main/post execution receive the same captured variable map.
A missing variable evaluates to an empty string. Values are strings: the value
`false` is not a boolean. Compare explicitly, for example `vars.FLAG == 'true'`.

Values are evaluated once. A literal `${{ ... }}` inside a configured value is
never evaluated recursively. Direct interpolation into shell source can execute
shell code; pass untrusted values through `env` or Action inputs instead.

At run creation, the complete variable map is captured in the same database
transaction as the immutable run snapshot. Settings changes after that point do
not affect queued/running jobs or downstream jobs. Snapshot reruns preserve the
original map even if settings were edited or deleted; create a new run to pick up
new values. Manual, push and approved MR runs follow the same snapshot policy.

This does not introduce dynamic matrices, variable-based `runs-on`/display names,
organization/environment variable precedence, or environment approval policies.
The AWS example requires explicit `id-token: write` and an operator-configured
issuer; see [workflow OIDC](workflow-oidc.md).

## Upgrade and validation

The baseline schema includes repository variable storage. Variables introduced
definition version 6 and assignment version 9. Current snapshots use definition
v7 / assignment v10 for [workflow OIDC](workflow-oidc.md). Upgrade coordinator,
providers and runners together. Historical definition versions 1–5 remain
readable; reruns retain their original contracts and do not acquire a new `vars`
context. Older JSON contexts and plans default missing variable maps to empty
values during decoding.

Regression tests cover baseline persistence and cascade deletion, authorization,
optimistic versions, repository isolation, naming/value/aggregate limits,
API/CLI/MCP/browser submission, escaping and CSRF, captured values through
setting changes and reruns, MR/push contexts, and real HTTP execution with
downstream outputs. Runtime tests cover case-insensitive/missing lookup,
composite inputs, post handlers, nonrecursive values, no automatic environment
injection and legacy context gates.

```sh
moon test --strip -j 1 --deny-warn
node --test runner/actions/*.test.mjs
node scripts/check-package-boundaries.cjs
```

Definition-v7 jobs without `id-token: write` retain assignment v9 compatibility;
only OIDC-enabled jobs require assignment v10.
