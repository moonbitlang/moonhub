# Repository Deploy Keys

Status: TODO

## Goal

Support SSH deploy keys scoped to one repository, so deployment servers can
pull source without inheriting a user's or site administrator's Git access.
The current deployment key is attached to the root account as a temporary
workaround; it is not a least-privilege, repository-scoped credential.

## Scope

- Repository owners/admins manage deploy keys in repository settings.
- Accept SSH public keys only. Never request or store a private key.
- Default to read-only clone/fetch access. Writable keys require an explicit
  permission choice and must still obey branch protection.
- Store a name, fingerprint, access mode, creator, creation time, last use and
  revocation state. Record additions, permission changes and revocations in audit.
- Distinguish deploy-key authentication from user-key authentication. Recheck
  the repository binding and access mode for each Git operation.
- Define whether the same public key may be bound to multiple repositories;
  revoking one binding must not silently grant or revoke another repository.
- Apply existing SSH transport restrictions, CSRF protection, error redaction
  and key-format validation. Do not grant interactive shell, forwarding, admin
  access or Pipeline execution permissions merely by registering a deploy key.

## Acceptance

- A read-only key can clone/fetch its repository but cannot push.
- Access to another repository is denied, including by changing the SSH command.
- A writable key can push only to its authorized repository and cannot bypass
  protected branches or push-trigger execution authorization.
- Revocation rejects subsequent operations; repository deletion invalidates its
  bindings. Duplicate keys, user-key collisions and reuse have explicit tests.
- Unauthorized users cannot manage deploy keys. UI and HTTP tests cover
  creation, permissions, revocation and repository isolation.
- Deployment documentation explains generation on the server, public-key
  registration, strict host verification, rotation and revocation.

## Current Deployment Migration

After implementation, register a read-only deploy key for `compiler/moonhub`,
update the server's deployment clone to use it, verify `git pull --ff-only`,
then revoke the temporary root-account key `moonhub-server-deploy`. Do not
remove the working key before the replacement has been verified.
