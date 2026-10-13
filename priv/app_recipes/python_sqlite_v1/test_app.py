"""Recipe acceptance: initialize, preserve persisted writes, and pass SQLite integrity."""
import pathlib
import sqlite3
import subprocess
import tempfile
import unittest


class PersistenceTest(unittest.TestCase):
    def test_initialization_keeps_existing_notes(self):
        with tempfile.TemporaryDirectory() as directory:
            command = ["python3", "app.py", "--check", "--data-dir", directory]
            subprocess.run(command, check=True, timeout=15)
            database = pathlib.Path(directory) / "app.sqlite"
            with sqlite3.connect(str(database)) as db:
                db.execute("INSERT INTO notes (body) VALUES (?)", ("A retained note",))
                db.commit()
            subprocess.run(command, check=True, timeout=15)
            with sqlite3.connect(str(database)) as db:
                self.assertEqual(db.execute("SELECT body FROM notes").fetchall(), [("A retained note",)])
                self.assertEqual(db.execute("PRAGMA integrity_check").fetchone()[0], "ok")


if __name__ == "__main__":
    unittest.main()
