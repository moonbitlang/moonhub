# Workflow OIDC identities

MoonHub can issue short-lived RS256 identity tokens to live workflow jobs that
explicitly grant `id-token: write`. Unmodified JavaScript/composite Actions and
shell steps receive the standard `ACTIONS_ID_TOKEN_REQUEST_URL` and
`ACTIONS_ID_TOKEN_REQUEST_TOKEN` variables. This supports upstream
`aws-actions/configure-aws-credentials@v5` without storing AWS access keys in a
repository or forwarding coordinator/provider credentials.

## Enable an issuer

OIDC is disabled by default. Configure one stable, publicly reachable HTTPS
origin, with no path, explicit port, credentials, query or fragment.
The origin is operator configuration; request Host/Forwarded headers and workflow
YAML cannot override it. AWS must be able to retrieve its discovery document and
JWKS over trusted HTTPS. Configure TLS at the existing reverse proxy.

Generate a private configuration file outside repositories, runner images,
workspaces and backups intended for users. The following writes a new file with
mode 0600 and refuses to overwrite an existing file:

```sh
node - /absolute/private/oidc.json https://ci.example.com <<'JS'
const fs = require('node:fs');
const { generateKeyPairSync } = require('node:crypto');
const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 3072 });
fs.writeFileSync(process.argv[2], JSON.stringify({
  issuer: process.argv[3],
  private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
  audiences: ['sts.amazonaws.com'],
  previous_keys: []
}), { mode: 0o600, flag: 'wx' });
JS
```

Set `MOONHUB_OIDC_CONFIG` to the file's absolute path in the Web server's
environment and restart the server. Configuration is loaded once at startup;
invalid configuration fails startup. It accepts a PEM RSA private key of
2048–4096 bits, at most seven previous **public** RSA JWKs, and 1–16 allowed
ASCII audiences of 1–256 bytes. The default audience is `sts.amazonaws.com`.
Requests omitting `audience` use the first configured audience. Unconfigured
audiences are rejected. Additional configuration fields are rejected.

The Web image already supplies Node. `MOONHUB_OIDC_NODE` optionally selects an
absolute Node executable. Signing uses the standard Node crypto/OpenSSL
implementation in bounded, isolated child processes (four concurrent signing
slots, ten-second queue and signing timeouts). Private material travels through
stdin, never argv, environment, generated job files or runner assignments.

For Compose, use an operator-owned override to mount the file only in `web`:

```yaml
services:
  web:
    environment:
      MOONHUB_OIDC_CONFIG: /run/secrets/workflow_oidc
    volumes:
      - /absolute/private/oidc.json:/run/secrets/workflow_oidc:ro
```

The file must be readable by the Web process's configured service user. Keep the
same issuer and active configuration on every Web replica. No keys are generated
automatically at startup, so a restart never silently changes issuer identity.

## Workflow permissions and claims

```yaml
on: workflow_dispatch
permissions:
  contents: read
  id-token: write
jobs:
  publish:
    runs-on: ubuntu-24.04
    steps:
      - uses: aws-actions/configure-aws-credentials@v5
        with:
          role-to-assume: ${{ vars.OPENSEEK_RELEASE_AWS_ROLE_ARN }}
          aws-region: ${{ vars.OPENSEEK_S3_REGION }}
      - run: aws sts get-caller-identity
```

OIDC defaults to denied. A Job-level permissions mapping replaces the complete
workflow mapping: `permissions: {contents: read}` removes inherited OIDC access;
`permissions: {id-token: write}` also denies automatic source checkout. Empty
mappings and `id-token: none` deny OIDC. Unsupported permission scopes and
`id-token: read` remain validation errors.

JWTs include `iss`, `sub`, `aud`, `iat`, `nbf`, `exp`, a random `jti`, repository
name and numeric ID, captured ref/SHA, run ID, logical job ID, event name and
`workflow_ref` (repository/workflow path at the saved commit). Their maximum
lifetime is five minutes, capped by the job deadline. Claims come from the saved
run and server records; callers select only an allowed audience.

Subjects deliberately use the repository's non-reused numeric database ID:

- Push/manual: `repo_id:42:ref:refs/heads/main`
- Pull-request checks: `repo_id:42:pull_request`

A pull request never receives a branch subject, even when it targets `main`.
Repository IDs survive renames, and deleting/recreating a name does not inherit
its old identity. In branch subjects `%` and `:` are escaped as `%25` and `%3A`.
This subject format is a MoonHub contract; GitHub's `repo:owner/name:...` subject
must not be copied into the MoonHub trust policy unchanged.

Public endpoints are `/.well-known/openid-configuration` and `/-/oidc/jwks`.
The token endpoint is `GET /-/oidc/token?attempt_id=ID&audience=AUDIENCE` and
returns `{"value":"JWT"}`. Its bearer is a separate random, execution-bound
credential, obtained by the authenticated native runner after start. Attempt,
provider, browser and Artifact/Cache runtime credentials cannot substitute for
it. Cookies do not authorize this endpoint. Responses use `Cache-Control:
no-store`; duplicate/unknown query parameters are rejected.

Grants and issued JWTs are masked in server logs and removed from published job
outputs. The Action runtime masks request credentials and honors upstream
`add-mask` commands. Reserved OIDC environment values cannot be replaced through
workflow env, composite env or `GITHUB_ENV` commands.

Each attempt permits at most 128 runtime grants and 256 token signing requests.
Runtime grants expire within one hour and before the job deadline; later steps
can obtain new grants. Every exchange rechecks execution identity, permission,
lease, deadline, cancellation, provider scope/revocation and requesting user's
current authorization before queueing, before signing and before returning a
JWT. Completion removes grants; the existing cleanup worker also removes expired
grants for inactive attempts. Expired grants are retained during a live attempt
so issuance budgets cannot reset. A configuration change takes effect after a server restart.

An already issued JWT remains cryptographically valid until its expiry; stopping
a job prevents further issuance. AWS credentials already exchanged from that JWT
follow AWS's own session lifetime and revocation policy.

## AWS trust configuration

Create an IAM OIDC provider for the configured HTTPS issuer and audience
`sts.amazonaws.com`. Restrict the role's trust to both the intended audience and
an exact subject. For repository ID 42 and the `main` branch:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::123456789012:oidc-provider/ci.example.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "ci.example.com:aud": "sts.amazonaws.com",
        "ci.example.com:sub": "repo_id:42:ref:refs/heads/main"
      }
    }
  }]
}
```

Attach the required AWS resource policy to the role separately. `id-token: write`
authorizes identity issuance; AWS decides which resources the resulting role
session can access. GitHub's existing IAM provider does not establish trust in
MoonHub. Use a separate provider/role policy and validate the identity with
`aws sts get-caller-identity` before enabling an actual publishing step.

## Key rotation

The active `kid` is the base64url SHA-256 of its DER SPKI public key. JWKS never
includes private fields. To rotate with cached verifiers and multiple replicas:

1. Generate the next private key in a new private file. Export its public JWK.
2. Add that next public JWK to `previous_keys` on the current configuration and
   restart all replicas, publishing both keys before signing with the new one.
3. Switch the active private key on every replica, retaining the old public JWK
   in `previous_keys`. Restart and verify discovery/JWKS and signature validation.
4. Retain the old public key through the last old token's five-minute lifetime
   and the verifier's cache window before removing it.

The field `previous_keys` accepts inactive public keys in either rotation phase;
active-key duplicates and private JWK fields are rejected. Back up private keys
only through the operator's existing private-secret backup procedure.

## Upgrade and acceptance

Apply migration 037 and upgrade coordinator, provider/controller and runner
together. Definition v7 / assignment v10 add explicit OIDC permission; definition
versions 1–6 remain readable and their reruns retain saved versions. Historical
JSON without `id_token_write` decodes to false. Old runners reject v10 rather
than executing a missing permission contract. The lease/report protocol stays v1.

Build browser assets before Web tests. Ordinary tests cover permission
replacement, denied legacy snapshots, independent RSA verification, masking,
key rotation, lease/cancellation/revocation fencing, public discovery, query
validation and a real two-job native runner with shell and JS pre/main/post.

Opt-in upstream acceptance downloads and executes unmodified
`aws-actions/configure-aws-credentials` v5 pinned to
`61815dcd50bd041e203e49132bacad1fd04d2708`:

```sh
MOONHUB_OIDC_UPSTREAM=1 \
MOONHUB_OIDC_NODE20=/absolute/path/to/node20 \
moon test --strip -j 1 web/views/pipelines --filter '*OIDC upstream*'
```

The smoke uses real MoonHub discovery/JWKS/token HTTP endpoints and an isolated
local STS stub. The stub independently verifies the RSA signature, issuer,
audience, subject, SHA, run and expiry before returning **fake** temporary AWS
credentials. The upstream Action performs its WebIdentity exchange, account
check and post cleanup. `MOONHUB_OIDC_NODE20` selects the declared Node20 runtime;
when omitted only this local smoke defaults to the current Node executable.
Production runner runtime selection is unchanged.

This acceptance does not create an IAM provider, change AWS trust, call real STS
or publish anything. Real AWS validation requires the operator-owned public
issuer and restricted role. Runner aliases/platform inventory, authenticated
release APIs, full-history Git checkout and scheduled triggers remain separate
openseek migration work.

Observed local acceptance on November 10, 2026: the pinned upstream Action
passed the OIDC → local STS exchange, GetCallerIdentity account check and post
cleanup under the checksum-pinned Node 20.20.2 runtime.
