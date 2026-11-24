# Deployment environments

Repository owners and administrators manage deployment targets at
**Settings → Variables → Deployment environments**. Each target has a stable ID,
a name (letters, numbers, dots, underscores or hyphens), nonsecret variables,
secrets, and an optional list of required reviewers. Any one listed reviewer
with current repository membership can approve. Administrators have no implicit
approval bypass. Empty reviewer lists permit automatic admission.

```yaml
jobs:
  deploy:
    needs: build
    environment:
      name: production
      url: https://example.test
    concurrency: production
    runs-on: ubuntu-24.04
    steps:
      - run: ./deploy.sh
        env:
          REGION: ${{ vars.REGION }}
          TOKEN: ${{ secrets.DEPLOY_TOKEN }}
```

The scalar `environment: production` form is equivalent. Names and optional HTTPS
URLs may use `github`, `inputs`, repository `vars`, `needs`, `matrix`, and
`strategy` expressions. A target must exist when the run is created. The saved
ID prevents a deleted and recreated name from taking over an existing run.
Local reusable workflows and matrix jobs retain their own deployment targets.

After dependencies and the job condition pass, the run page displays the target
and its pending review. Approval binds the job in this workflow attempt, target
ID and current policy revision. Only then can the job reserve a job-concurrency
slot or obtain a runner assignment. Rejection fails the job; pending cancellation
and reviewer decisions remain in the job's review history. Policy changes reset
queued admission and cancel active execution through the existing lease/fencing
path. Current membership and policy are checked during admission and live API
access. Restarting the coordinator does not lose pending reviews.

Environment variables override repository variables in execution-time `vars`.
Job conditions, environment selection and scheduling use repository variables;
environment values cannot select or approve their own target. Run creation
captures public environment IDs and values. Full and failed-job reruns retain
that snapshot and request fresh approval for jobs that execute again. Reused
successful jobs keep their original results and deployment history.

Environment secrets override repository secrets with the same name. They are
never in run snapshots, assignments, read APIs or forms. Delivery requires a live
execution and running step after approval; the existing trusted-event restrictions
still apply, including denial for PR checks and tag pushes. Current secret access
is rechecked, while a value already delivered remains stable within the attempt.
Changing its scope cannot expose the old cached value through a repository
fallback. Log/output masking and credential cleanup are shared with repository
secrets. Reruns read current secret values.

Limits: 64 targets per repository, 16 reviewers per target, 64 secrets and 500
variables per target. Secret values are at most 16 KiB; individual variable values
are at most 48 KiB. Each environment's variable JSON and the merged execution
variables are at most 256 KiB and 500 entries. The complete public deployment
snapshot is at most 1 MiB. Oversized configuration fails explicitly.

Both REST mounts (`/-/api/v1` and `/api/v3`) support:

- `GET /repos/:owner/:repo/environments` returns public values and value revisions,
  secret names/revisions, IDs and protection settings; secret values are omitted.
- `POST /repos/:owner/:repo/environments/:name` accepts `version` and `reviewers`
  (user IDs). Use version `0` for creation and the returned version for updates.
- `POST /repos/:owner/:repo/environments/:name/delete` accepts `version`.
- `POST /repos/:owner/:repo/environments/:name/variables/:key` and the corresponding
  `secrets` route accept `version` and `value`; a JSON null value deletes it.
- `POST /repos/:owner/:repo/runs/:number/deployments/:job` accepts `environment_id`,
  `policy_version`, and `decision` (`approved` or `rejected`). It requires an
  execution-scoped token and the listed reviewer's identity. Repeating the same
  decision is idempotent; stale revisions return conflict.

Configuration changes require a write-scoped token plus repository management
permission. Run details include `deployments`, independently of provider execution
image metadata. Browser forms enforce the same business checks and CSRF binding.

Schema 53 adds configuration, immutable public snapshots, per-job admission and
append-only review records. No assignment protocol change is needed: execution
uses the existing variable and scoped-secret channels. Older workflow snapshots
without a deployment target keep their prior behavior.

Tests read the environment declaration from this repository's `deploy.yml`,
plan an equivalent job, exercise protection and
credential boundaries, and verify both API mounts and the browser forms. The complete GitHub deployment workflow still uses
`MOONHUB_DEPLOY_*` application variables that MoonHub intentionally reserves;
this change does not relax that namespace policy. Tests do
not configure a real cloud environment or perform a production deployment.
