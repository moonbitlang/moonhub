# Database initialization and upgrades

`base.sql` is the complete schema 38 DDL. It replaces migrations 001–038,
including their final tables, columns, defaults, constraints, indexes, views and
triggers. Historical data backfills are no longer part of fresh initialization.
The minimum supported existing database version is 38. The current
`database_schema_version` is 54. Migrations 039–054 extend the baseline.

Web calls `database.initialize_db` before becoming healthy. A database at version
53 is accepted without replaying DDL or reading schema files. Versions 38–52
read and apply only their missing incremental migrations in version order.
Version 0 is initialized only when it contains no user-defined database objects,
including views. For an empty database, the initializer reads `base.sql` and
migrations 039–054, obtains a write reservation with `BEGIN IMMEDIATE`, rechecks
version and objects, then creates the baseline, applies the migrations and sets
`PRAGMA user_version=53` in the same transaction. Any failure rolls back DDL,
data and version. Existing database upgrades use the same write reservation and
atomic commit. Do not run `base.sql` directly against an existing database or
change `user_version` manually to bypass the checks.

Existing databases below version 38 are rejected, as are databases newer than
the program supports. For an older database or backup:

1. Restore the complete backup with its matching application images and data,
   following [deployment recovery](../deploy/README.md#standard-restores).
2. Back up the restored installation before upgrading. Use a historical release
   containing migrations 001–038, such as commit `5b57e73`, to bring the database
   to version 38. Use that release's checkout and deployment data together.
3. Confirm `PRAGMA user_version` returns 38 before switching to the current
   Web/SSH release. Preserve the complete backup for rollback.

The complete backup/restore workflow is unchanged. It preserves the database,
repositories, attachment bytes and deployment state together. Legacy identity-only
transfer tools are no longer supplied.

Keep schema 38 as the existing-database floor. Migrations 039–048 continue above
this baseline; future incremental migrations must extend the supported-version
logic in `database/schema.mbt`. Fresh databases must reach the same schema as
upgraded databases in one atomic initialization transaction.

Schema 040 adds repository releases, durable published-asset storage and cleanup, live job API grants, immutable run display titles and opt-in UTC schedule ticks. Migration 039 remains the compatibility step for historical artifact/cache locations.

Schema 041 adds durable repository and attachment file cleanup journals. Deleting
a repository saves its Git and mirror directories for cleanup in the deletion
transaction. Attachment cascades journal their file IDs through a trigger;
Actions artifacts, caches and Release files retain their existing journals.
The server retries cleanup with cross-process volume locks and rejects unsafe
paths. Missing files count as cleaned. The repository name stays reserved until
its old Git directory is removed; mirror and attachment tasks use immutable IDs
so they cannot remove files belonging to a later repository with the same name.

Schema 042 adds `pipeline_worker.isolation_revision`, defaulting to zero. The
outside controller must acknowledge the current configuration revision after
disabling EC2 metadata before a privileged single-use worker can claim a job.

Schema 043 adds administrator-managed Linux provider environments, controller
capability fencing and immutable per-job environment snapshots. The shared
matching view keeps queue counts, diagnostics and claims consistent. Existing
providers retain single-image behavior until environments are explicitly saved.

Schema 044 adds the repository transfer journal and reserves destination names
against concurrent repository creation until each transfer commits or rolls back.

Schema 045 extends the durable Actions trigger queue for stable Release
publication. Existing Releases and push events are not replayed.

Schema 048 adds runner groups and repository grants. Existing providers retain
their current scope; groups grant no access until explicitly configured.
