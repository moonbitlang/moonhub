#!/usr/bin/env python3
"""Transfer accounts, teams and user SSH public keys without repositories or sessions."""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import sys

TABLES = json.loads(Path(__file__).with_name("identity-tables.json").read_text())


def readonly(path):
    return sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True)


def create_private(path):
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    return sqlite3.connect(path)


def copy_rows(source, target):
    counts = {}
    for table, columns in TABLES.items():
        names = ", ".join('"' + column + '"' for column in columns)
        rows = source.execute(f'SELECT {names} FROM "{table}"').fetchall()
        target.executemany(f'INSERT INTO "{table}" ({names}) VALUES ({", ".join("?" for _ in columns)})', rows)
        counts[table] = len(rows)
    return counts


def export_identities(source_path, destination):
    with readonly(source_path) as source:
        source.execute("BEGIN")
        version = source.execute("PRAGMA user_version").fetchone()[0]
        if version not in (11, 12, 13):
            raise ValueError("Unsupported source schema")
        target = create_private(destination)
        try:
            with target:
                target.execute("CREATE TABLE transfer_metadata (format INTEGER, source_schema INTEGER)")
                target.execute("INSERT INTO transfer_metadata VALUES (1, ?)", (version,))
                for table, columns in TABLES.items():
                    # Only the allowlisted columns are exported. No source schema
                    # SQL, triggers, server private keys or login sessions are copied.
                    names = ", ".join('"' + column + '"' for column in columns)
                    target.execute(f'CREATE TABLE "{table}" ({names})')
                return copy_rows(source, target)
        finally:
            target.close()


def import_identities(source_path, destination, schema_root, version):
    migrations = sorted(Path(schema_root, "migrations").glob("[0-9][0-9][0-9]_*.sql"))
    selected = [p for p in migrations if int(p.name[:3]) <= version]
    if [int(p.name[:3]) for p in selected] != list(range(1, version + 1)):
        raise ValueError("Migration sequence is incomplete")
    with readonly(source_path) as source:
        source.execute("BEGIN")
        if source.execute("SELECT format FROM transfer_metadata").fetchall() != [(1,)]:
            raise ValueError("Unsupported transfer format")
        if source.execute('SELECT COUNT(*) FROM "user" WHERE status = ? AND is_site_admin = 1', ("active",)).fetchone()[0] < 1:
            raise ValueError("An active site administrator is required")
        target = create_private(destination)
        try:
            target.execute("PRAGMA foreign_keys = ON")
            target.executescript(Path(schema_root, "base.sql").read_text())
            for migration in selected:
                target.executescript(migration.read_text())
            with target:
                counts = copy_rows(source, target)
                if target.execute("PRAGMA foreign_key_check").fetchall():
                    raise ValueError("Invalid identity references")
                target.execute(f"PRAGMA user_version = {version}")
            if target.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                raise ValueError("Database integrity check failed")
            return counts
        except Exception:
            target.close()
            Path(destination).unlink(missing_ok=True)
            raise
        finally:
            target.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    export = subcommands.add_parser("export")
    export.add_argument("source")
    export.add_argument("destination")
    load = subcommands.add_parser("import")
    load.add_argument("source")
    load.add_argument("destination")
    load.add_argument("--schema-root", required=True)
    load.add_argument("--schema-version", required=True, type=int, choices=(11, 12, 13))
    options = parser.parse_args()
    try:
        if options.command == "export":
            counts = export_identities(options.source, options.destination)
        else:
            counts = import_identities(options.source, options.destination, options.schema_root, options.schema_version)
        print(json.dumps({"status": "ok", "rows": counts}))
    except Exception as error:
        # Do not put account identifiers, password hashes or submitted values in logs.
        print(f"Identity transfer failed ({type(error).__name__}); source and existing destinations are unchanged.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
