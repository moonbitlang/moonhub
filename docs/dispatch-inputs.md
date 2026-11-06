# Workflow dispatch inputs

Manual runs accept `on.workflow_dispatch.inputs` from the exact selected source
revision. The browser form loads that revision's input definitions; the REST API,
CLI and MCP pass values through the same server validation. Downloaded GitHub
Actions use these values through the normal expression and event interfaces.

```yaml
name: Release preparation
on:
  workflow_dispatch:
    inputs:
      version:
        description: Release version
        type: string
        required: true
      publish:
        type: boolean
        default: false
      count:
        type: number
        default: 1
      channel:
        type: choice
        options: [stable, beta]
        default: stable
concurrency:
  group: release-${{ inputs.channel }}
  cancel-in-progress: inputs.publish
jobs:
  prepare:
    if: inputs.publish
    runs-on: ubuntu-24.04
    outputs:
      version: ${{ inputs.version }}
    steps:
      - env:
          VERSION: ${{ inputs.version }}
          COUNT: ${{ inputs.count }}
        run: printf '%s (%s)\n' "$VERSION" "$COUNT"
```

## Validation and submission

Supported types are `string` (also the default when omitted), `boolean`, `number`
and `choice`. Definitions support `description`, `required`, `default` and choice
`options`. Unknown fields, unsupported types and invalid defaults fail workflow
validation. Environment inputs are rejected: environment selection and approval
policy are not implemented.

Names are identifiers beginning with an ASCII letter or underscore, followed by
ASCII letters, digits, underscores or hyphens, up to 100 characters. Case-colliding
names and prototype-related names are rejected. Supplied names must match the
definition exactly; expression field lookup remains case-insensitive.

Unknown input keys, missing required values, empty required strings, null, nested
objects/arrays, NUL, non-finite numbers and invalid choice values are rejected
before a run is published. False and zero satisfy required inputs. Boolean and
number values may be JSON scalars or valid string representations for forms;
string inputs must remain strings. Boolean strings are `true`/`false`.
Choice matching is exact. YAML number defaults are normalized to JSON numbers.

Omitted inputs use their defaults. Optional inputs without a default become
`false`, `0`, or an empty string according to type; an omitted optional choice
also becomes an empty string. At most 25 definitions/values are accepted. Both
the supplied and resolved input objects are bounded to 65,535 UTF-8 JSON bytes,
including names and JSON punctuation/escaping. Transport envelopes have separate
bounded overhead allowances. Inputs are public run metadata, not secrets.

Create a JSON file, then submit it through the CLI:

```json
{"version":"1.2.3","publish":true,"count":2.5,"channel":"beta"}
```

```sh
moonhub ci run --repo owner/repository --branch main \
  --workflow .github/workflows/release.yml \
  --inputs-file /absolute/path/inputs.json --json
```

`POST /-/api/v1/repos/:owner/:repo/runs` accepts the existing `branch` and
`workflow` fields plus an optional `inputs` JSON object. MCP
`moonhub_create_run` accepts the same optional object. Execution authorization
and repository-owner/admin requirements are unchanged. Browser submissions also
retain session and CSRF validation, and preserve input values on errors.

## Snapshot and execution

Resolved typed values are saved in the immutable run context together with the
source revision. Moving a branch or editing its workflow cannot change them.
Snapshot reruns retain the original definitions and values; create a new manual
run to change inputs. Push and pull-request runs receive an empty `inputs` context
even when their workflow also declares dispatch defaults.

`inputs.NAME` preserves booleans and numbers. `github.event.inputs.NAME` contains
strings. They are available in job conditions, workflow concurrency, declared job
outputs, step conditions, `run`, `env` and Action `with` templates. They do not
add dynamic matrix expansion or input-based runner selectors. Composite Actions
use their own `inputs` while executing; `github.event.inputs` still refers to the
workflow dispatch, and the enclosing inputs are restored afterward.

`github.event` and `GITHUB_EVENT_PATH` expose the captured event input map,
`repository.full_name` and `ref`. The ref matches `github.ref`, including the
merge ref for pull-request runs. This is a minimal event payload, not a full
GitHub webhook implementation. The runner writes a private event file for every
script/Action pre/main/post invocation, deletes it afterward, and recreates it
from the captured payload so one child cannot overwrite a later child's event.

Templates evaluate once. A supplied literal `${{ ... }}` is data and is never
recursively interpreted. Pass untrusted input through `env` or `with`; direct
interpolation into shell source can execute shell code.

## Upgrade and verification

New snapshots use definition version 5 and assignment version 8. Upgrade the
coordinator, provider/controller and runner together; old executors reject the
new version instead of silently losing inputs. Definition versions 1-4 remain
readable, and reruns retain their original assignment contracts. Legacy context
and job-plan JSON defaults missing input/event fields to empty maps. Legacy
assignments preserve their original expression contexts and do not receive the
new event file; server scheduling uses the same version boundary. No database
migration is required: the existing immutable `context_json` stores the values.
The runner bounds event JSON to 192 KiB, including its stringified input map.

Tests cover schema/type/size validation, numeric YAML normalization, all four
submission interfaces, immutable reruns, old wire contracts, conditions,
concurrency and job outputs. Native HTTP acceptance executes two real runner jobs
with typed input expressions and event files. JavaScript runtime tests also cover
JavaScript Action input delivery, nested composite input isolation, nonrecursive
values and fresh pre/main/post event files.

```sh
moon test --strip -j 1
node --test runner/actions/runtime.test.mjs
```

Scheduled triggers, vars, dynamic matrices, environment policy, OIDC and
authenticated release APIs remain separate migration work.
