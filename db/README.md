# Database initialization and upgrades

`base.sql` is the complete schema 38 DDL. It replaces migrations 001–038,
including their final tables, columns, defaults, constraints, indexes, views and
triggers. Historical data backfills are no longer part of fresh initialization.
The minimum supported existing database version is 38. The current
`database_schema_version` is 39; `migrations/039_blob_storage.sql` remains an
incremental migration above the baseline.

Web calls `database.initialize_db` before becoming healthy. A database at version
39 is accepted without replaying DDL or reading schema files. Version 38 reads
only migration 039. Version 0 is initialized only when it contains no
user-defined database objects, including views. For an empty database, the
initializer reads `base.sql` and migration 039, obtains a write reservation with
`BEGIN IMMEDIATE`, rechecks version and objects, then creates the baseline,
applies migration 039 and sets `PRAGMA user_version=39` in the same transaction.
Any failure rolls back DDL, data and version. Existing schema 38 upgrades use the
same write reservation and atomic commit. Do not run `base.sql` directly against
an existing database or change `user_version` manually to bypass the checks.

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

Keep schema 38 as the existing-database floor. Migration 039 continues above
this baseline; future incremental migrations must extend the supported-version
logic in `database/schema.mbt`. Fresh databases must reach the same schema as
upgraded databases in one atomic initialization transaction.
