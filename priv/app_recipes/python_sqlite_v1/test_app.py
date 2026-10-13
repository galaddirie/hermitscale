"""Recipe acceptance: initialize, preserve persisted writes, and pass SQLite integrity."""
import pathlib
import sqlite3
import subprocess
import tempfile
import unittest


class PersistenceTest(unittest.TestCase):
    def test_initialization_preserves_application_owned_data(self):
        with tempfile.TemporaryDirectory() as directory:
            command = ["python3", "app.py", "--check", "--data-dir", directory]
            subprocess.run(command, check=True, timeout=15)
            database = pathlib.Path(directory) / "app.sqlite"
            with sqlite3.connect(str(database)) as db:
                self.assertEqual(db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").fetchall(), [])
                db.execute("CREATE TABLE sample_records (value TEXT NOT NULL)")
                db.execute("INSERT INTO sample_records (value) VALUES (?)", ("Retained data",))
                db.commit()
            subprocess.run(command, check=True, timeout=15)
            with sqlite3.connect(str(database)) as db:
                self.assertEqual(db.execute("SELECT value FROM sample_records").fetchall(), [("Retained data",)])
                self.assertEqual(db.execute("PRAGMA integrity_check").fetchone()[0], "ok")


if __name__ == "__main__":
    unittest.main()
