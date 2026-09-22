import importlib.util
from pathlib import Path
import sqlite3
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("transfer", ROOT / "deploy/identity-transfer.py")
transfer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transfer)


class TransferTest(unittest.TestCase):
    def test_only_identities_and_invitations_survive(self):
        with tempfile.TemporaryDirectory() as directory:
            old, package, new = [Path(directory, name) for name in ("old.db", "identities.db", "new.db")]
            with sqlite3.connect(old) as db:
                db.executescript((ROOT / "db/base.sql").read_text())
                for migration in sorted((ROOT / "db/migrations").glob("*.sql")):
                    db.executescript(migration.read_text())
                db.executescript("""
                    PRAGMA user_version = 12;
                    INSERT INTO "user" (id, name_key, display_name, email, password_hash, is_site_admin) VALUES (5, 'root', 'Root', 'root@example.invalid', 'private-hash-fixture', 1);
                    INSERT INTO "user" (id, name_key, display_name, password_hash, status) VALUES (8, 'disabled', 'Disabled', 'other-hash-fixture', 'disabled');
                    INSERT INTO team (id, name_key, display_name, kind) VALUES (4, 'compiler', 'Compiler', 'org');
                    INSERT INTO team_member (team_id, user_id, role) VALUES (4, 5, 'owner');
                    INSERT INTO invitation (id, kind, email, name_key, display_name, password_hash, team_id, team_role, invited_by_user_id) VALUES (9, 'team_member', 'pending@example.invalid', 'pending', 'Pending', 'invitation-fixture', 4, 'member', 5);
                    INSERT INTO session (user_id, token_hash, expires_at) VALUES (5, 'do-not-copy-session', '2099-01-01');
                    INSERT INTO ssh_key (user_id, title, public_key, fingerprint) VALUES (5, 'laptop', 'key-fixture', 'key-fingerprint');
                    INSERT INTO ssh_key (user_id, title, public_key, fingerprint, revoked_at) VALUES (5, 'revoked', 'revoked-key-fixture', 'revoked-fingerprint', '2026-01-01');
                    INSERT INTO repository (team_id, name) VALUES (4, 'do-not-copy-repo');
                """)
            counts = transfer.export_identities(old, package)
            self.assertEqual(counts, {"user": 2, "team": 1, "team_member": 1, "invitation": 1, "ssh_key": 2})
            self.assertEqual(stat.S_IMODE(package.stat().st_mode), 0o600)
            with sqlite3.connect(package) as db:
                tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                self.assertEqual(tables, set(transfer.TABLES) | {"transfer_metadata"})
            self.assertEqual(transfer.import_identities(package, new, ROOT / "db", 11), counts)
            self.assertEqual(stat.S_IMODE(new.stat().st_mode), 0o600)
            with sqlite3.connect(new) as db:
                self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 11)
                self.assertEqual(db.execute('SELECT id, password_hash, status FROM "user" ORDER BY id').fetchall(), [(5, 'private-hash-fixture', 'active'), (8, 'other-hash-fixture', 'disabled')])
                self.assertEqual(db.execute("SELECT team_id, user_id, role FROM team_member").fetchall(), [(4, 5, 'owner')])
                self.assertEqual(db.execute("SELECT user_id, title, public_key, revoked_at FROM ssh_key ORDER BY id").fetchall(), [(5, 'laptop', 'key-fixture', None), (5, 'revoked', 'revoked-key-fixture', '2026-01-01')])
                for table in ("session", "invitation_session", "repository", "pipeline_run", "pipeline_provider", "email_outbox", "password_reset"):
                    self.assertEqual(db.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0], 0)
            with self.assertRaises(FileExistsError):
                transfer.import_identities(package, new, ROOT / "db", 11)
            node_export = Path(directory, "node-export.db")
            result = subprocess.run(["node", str(ROOT / "deploy/export-identities.cjs"), str(old), str(node_export)], capture_output=True, text=True, check=True)
            self.assertNotIn("private-hash-fixture", result.stdout + result.stderr)
            self.assertNotIn("key-fixture", result.stdout + result.stderr)
            node_import = Path(directory, "node-import.db")
            self.assertEqual(transfer.import_identities(node_export, node_import, ROOT / "db", 11), counts)
            with sqlite3.connect(node_import) as db:
                self.assertEqual(db.execute('SELECT password_hash FROM "user" WHERE id = 5').fetchone()[0], 'private-hash-fixture')
                self.assertEqual(db.execute("SELECT COUNT(*) FROM ssh_key WHERE revoked_at IS NOT NULL").fetchone()[0], 1)


if __name__ == "__main__":
    unittest.main()
