#!/usr/bin/env python3
"""Bounded recipe operations. Remote code and data stay in separate directories."""
import argparse
from contextlib import closing
import hashlib
import io
import json
import os
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path("/workspace")
MAX_BUNDLE = 1048576
p = argparse.ArgumentParser()
p.add_argument("action", choices=["freeze", "build", "preview", "stage", "backup", "restore", "mark", "inspect"])
p.add_argument("--operation", required=True)
p.add_argument("--revision")
p.add_argument("--digest")
p.add_argument("--previous")
p.add_argument("--root", default="/workspace")
a = p.parse_args()
ROOT = Path(a.root)
if len(a.operation) != 36 or any(c not in "0123456789abcdef-" for c in a.operation):
    raise SystemExit("Invalid operation")
releases = ROOT / "releases"
data = ROOT / "data"
incoming = ROOT / "incoming"
for directory in [releases, data, incoming]:
    directory.mkdir(parents=True, exist_ok=True)
marker = data / "release-marker.json"

def emit(value):
    print(json.dumps(value, sort_keys=True))

def run(command, cwd):
    subprocess.run(command, cwd=str(cwd), check=True, timeout=240)

def verified_extract(bundle, destination, code=True):
    if bundle.stat().st_size > MAX_BUNDLE:
        raise SystemExit("App bundle exceeds small-app profile")
    with tarfile.open(bundle) as archive:
        members = archive.getmembers()
        total = sum(m.size for m in members)
        if total > 8388608:
            raise SystemExit("Expanded app exceeds profile")
        for member in members:
            parts = Path(member.name).parts
            if member.issym() or member.islnk() or member.isdev() or not parts or member.name.startswith("/") or ".." in parts:
                raise SystemExit("Unconfined archive member")
            if code and (any(part in [".git", ".codex", ".hermitscale", "data", "preview-data", "credentials.json", "id_rsa", "id_ed25519"] or part.startswith(".env") for part in parts) or member.name.endswith((".sqlite", ".sqlite-wal", ".sqlite-shm", ".pem", ".key"))):
                raise SystemExit("Runtime data or credentials in bundle")
            if not code and parts[0] not in ["app.sqlite", "uploads"]:
                raise SystemExit("Unexpected data backup member")
        archive.extractall(destination, members=members, filter="data")

if a.action == "freeze":
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if head != a.revision:
        raise SystemExit("Expected source commit changed")
    paths = subprocess.check_output(["git", "diff", "--name-only", "HEAD", "-z"], cwd=ROOT).split(b"\0")
    paths += subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=ROOT).split(b"\0")
    runtime_dirs = {"incoming", "releases", "preview-releases", "data", "preview-data", "app-tools", "builds", "backups", "recovery"}
    manifest = []
    for raw in sorted(set(path for path in paths if path)):
        path = raw.decode("utf-8")
        parts = Path(path).parts
        if parts[0] in runtime_dirs:
            continue
        if path.startswith("/") or ".." in parts or any(part in [".codex", ".hermitscale", "credentials.json", "id_rsa", "id_ed25519"] or part.startswith(".env") for part in parts) or path.endswith((".sqlite", ".sqlite-wal", ".sqlite-shm", ".pem", ".key")):
            raise SystemExit("Source manifest contains runtime data or credentials")
        target = ROOT / path
        if target.is_symlink() or (target.exists() and target.stat().st_size > MAX_BUNDLE):
            raise SystemExit("Source manifest exceeds profile or contains a symlink")
        manifest.append(path)
    if len(manifest) > 100:
        raise SystemExit("Source manifest exceeds 100 files")
    if manifest:
        # Disable repository hooks. The release owns exactly this admitted manifest.
        run(["git", "add", "--"] + manifest, ROOT)
        run(["git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=Hermitscale", "-c", "user.email=apps@hermitscale.invalid", "commit", "--no-gpg-sign", "-m", "Freeze app source " + a.operation, "--"] + manifest, ROOT)
    frozen = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    emit({"revision": frozen, "base_revision": head, "change_manifest": manifest})
elif a.action == "build":
    if not a.revision or not all(c in "0123456789abcdef" for c in a.revision) or len(a.revision) != 40:
        raise SystemExit("A full source commit is required")
    head = subprocess.check_output(["git", "rev-parse", a.revision], cwd=ROOT, text=True).strip()
    if head != a.revision:
        raise SystemExit("Source commit mismatch")
    archive = incoming / (a.operation + ".tar")
    with archive.open("wb") as output:
        subprocess.run(["git", "archive", "--format=tar", a.revision], cwd=ROOT, stdout=output, check=True, timeout=60)
    stage = ROOT / "builds" / a.operation
    stage.mkdir(parents=True, exist_ok=True)
    verified_extract(archive, stage)
    run(["python3", "-m", "compileall", "-q", "."], stage)
    run(["python3", "-m", "unittest", "discover", "-v"], stage)
    with tempfile.TemporaryDirectory() as test_data:
        run(["python3", "app.py", "--check", "--data-dir", test_data, "--revision", a.revision], stage)
    source_proof = json.dumps({"source_commit": head, "recipe": "python-sqlite-v1"}).encode()
    with tarfile.open(archive, "a") as bundle:
        entry = tarfile.TarInfo("_hermitscale_source.json")
        entry.size = len(source_proof)
        bundle.addfile(entry, io.BytesIO(source_proof))
    emit({"revision": head, "digest": hashlib.sha256(archive.read_bytes()).hexdigest(), "path": "incoming/" + a.operation + ".tar", "checks": ["compile", "unit_tests", "database_integrity"]})
elif a.action in ["stage", "preview"]:
    archive = incoming / (a.operation + ".tar")
    if hashlib.sha256(archive.read_bytes()).hexdigest() != a.digest:
        raise SystemExit("Artifact digest mismatch")
    destination = (releases if a.action == "stage" else ROOT / "preview-releases") / a.operation
    destination.mkdir(parents=True, exist_ok=True)
    verified_extract(archive, destination)
    proof = json.loads((destination / "_hermitscale_source.json").read_text())
    if proof != {"source_commit": a.revision, "recipe": "python-sqlite-v1"}:
        raise SystemExit("Frozen source identity mismatch")
    run(["python3", "-m", "compileall", "-q", "."], destination)
    with tempfile.TemporaryDirectory() as test_data:
        run(["python3", "app.py", "--check", "--data-dir", test_data, "--revision", a.revision], destination)
    # The approved source controls its bounded migration. Customer data is never imported from the build.
    migration = destination / "migrate.py"
    if migration.exists() and a.action == "stage":
        run(["python3", "migrate.py", "--data-dir", str(data)], destination)
    emit({"staged": a.operation, "revision": a.revision, "digest": a.digest, "migration": migration.exists()})
elif a.action == "backup":
    db = data / "app.sqlite"
    backup_dir = ROOT / "backups" / a.operation
    backup_dir.mkdir(parents=True, exist_ok=True)
    if db.exists():
        with closing(sqlite3.connect(str(db))) as source, closing(sqlite3.connect(str(backup_dir / "app.sqlite"))) as target:
            source.backup(target)
            integrity = target.execute("PRAGMA integrity_check").fetchone()[0]
            if integrity != "ok":
                raise SystemExit("SQLite backup integrity failed")
    uploads = data / "uploads"
    if uploads.exists():
        shutil.copytree(uploads, backup_dir / "uploads", dirs_exist_ok=True, symlinks=True)
    archive = incoming / (a.operation + ".backup.tar")
    with tarfile.open(archive, "w") as bundle:
        for child in sorted(backup_dir.iterdir()):
            if child.name in ["app.sqlite", "uploads"]:
                bundle.add(child, arcname=child.name)
    # Exercise restoring the independent backup before exporting it.
    with tempfile.TemporaryDirectory() as restore_dir:
        verified_extract(archive, Path(restore_dir), code=False)
        restored = Path(restore_dir) / "app.sqlite"
        if restored.exists():
            with sqlite3.connect(str(restored)) as check:
                if check.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise SystemExit("SQLite restoration check failed")
    emit({"operation_id": a.operation, "path": "incoming/" + a.operation + ".backup.tar", "digest": hashlib.sha256(archive.read_bytes()).hexdigest(), "integrity": "ok", "restoration": "verified"})
elif a.action == "restore":
    recovery_marker = data / "data-recovery-marker.json"
    if recovery_marker.exists():
        recorded = json.loads(recovery_marker.read_text())
        if recorded.get("restored") == a.operation and recorded.get("digest") == a.digest:
            emit(recorded)
            raise SystemExit(0)
    archive = incoming / (a.operation + ".backup.tar")
    if hashlib.sha256(archive.read_bytes()).hexdigest() != a.digest:
        raise SystemExit("Backup digest mismatch")
    restored = ROOT / "recovery" / a.operation
    restored.mkdir(parents=True, exist_ok=True)
    verified_extract(archive, restored, code=False)
    db = restored / "app.sqlite"
    if db.exists():
        with sqlite3.connect(str(db)) as check:
            if check.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise SystemExit("Recovered database integrity failed")
        for suffix in ["", "-wal", "-shm"]:
            (data / ("app.sqlite" + suffix)).unlink(missing_ok=True)
        shutil.copy2(db, data / "app.sqlite")
        os.chmod(data / "app.sqlite", 0o660)
    uploads = restored / "uploads"
    if uploads.exists():
        shutil.rmtree(data / "uploads", ignore_errors=True)
        shutil.copytree(uploads, data / "uploads")
        for directory, directories, files in os.walk(data / "uploads"):
            os.chmod(directory, 0o2770)
            for filename in files:
                os.chmod(Path(directory) / filename, 0o660)
    result = {"restored": a.operation, "digest": a.digest, "integrity": "ok"}
    temporary = recovery_marker.with_suffix(".pending")
    with temporary.open("w") as output:
        json.dump(result, output)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, recovery_marker)
    emit(result)
elif a.action == "mark":
    value = {"operation_id": a.operation, "revision": a.revision, "artifact_digest": a.digest, "previous_deployment_id": a.previous}
    temporary = marker.with_suffix(".pending")
    with temporary.open("w") as output:
        json.dump(value, output)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, marker)
    emit(value)
elif a.action == "inspect":
    emit(json.loads(marker.read_text()) if marker.exists() else {"operation_id": None})
