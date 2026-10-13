defmodule Hermitscale.Apps.RecipeTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "hermitscale-app-recipe-" <> Ecto.UUID.generate())
    File.mkdir_p!(root)

    File.cp!(
      Application.app_dir(:hermitscale, "priv/app_recipes/python_sqlite_v1/app.py"),
      Path.join(root, "app.py")
    )

    File.cp!(
      Application.app_dir(:hermitscale, "priv/app_recipes/python_sqlite_v1/test_app.py"),
      Path.join(root, "test_app.py")
    )

    File.write!(
      Path.join(root, ".gitignore"),
      "app-tools/\nincoming/\nreleases/\npreview-releases/\nbuilds/\nbackups/\nrecovery/\ndata/\npreview-data/\n"
    )

    git!(root, ["init"])
    git!(root, ["add", "app.py", "test_app.py", ".gitignore"])

    git!(root, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.test",
      "commit",
      "-m",
      "Initial app"
    ])

    head = git!(root, ["rev-parse", "HEAD"]) |> String.trim()
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, head: head}
  end

  test "freezes exactly admitted app changes and verifies the archive source identity", %{
    root: root,
    head: head
  } do
    File.write!(Path.join(root, "about.txt"), "A useful app")
    File.mkdir_p!(Path.join(root, "preview-data"))
    File.write!(Path.join(root, "preview-data/customer.txt"), "Never publish preview data")
    operation = Ecto.UUID.generate()
    frozen = recipe!(root, ["freeze", "--operation", operation, "--revision", head])
    assert frozen["base_revision"] == head
    assert frozen["revision"] != head
    assert frozen["change_manifest"] == ["about.txt"]
    built = recipe!(root, ["build", "--operation", operation, "--revision", frozen["revision"]])
    assert built["revision"] == frozen["revision"]
    assert built["checks"] == ["compile", "unit_tests", "database_integrity"]

    staged =
      recipe!(root, [
        "stage",
        "--operation",
        operation,
        "--revision",
        frozen["revision"],
        "--digest",
        built["digest"]
      ])

    assert staged["staged"] == operation
    assert File.read!(Path.join([root, "releases", operation, "about.txt"])) == "A useful app"
    refute File.exists?(Path.join([root, "releases", operation, "preview-data"]))

    proof =
      Path.join([root, "releases", operation, "_hermitscale_source.json"])
      |> File.read!()
      |> Jason.decode!()

    assert proof == %{"source_commit" => frozen["revision"], "recipe" => "python-sqlite-v1"}
  end

  test "rejects credential files and source identity mismatches", %{root: root, head: head} do
    File.write!(Path.join(root, ".env"), "secret=private")

    assert {_output, code} =
             recipe(root, ["freeze", "--operation", Ecto.UUID.generate(), "--revision", head])

    assert code != 0
    File.rm!(Path.join(root, ".env"))
    operation = Ecto.UUID.generate()
    built = recipe!(root, ["build", "--operation", operation, "--revision", head])

    assert {output, code} =
             recipe(root, [
               "stage",
               "--operation",
               operation,
               "--revision",
               String.duplicate("a", 40),
               "--digest",
               built["digest"]
             ])

    assert code != 0
    assert output =~ "Frozen source identity mismatch"
  end

  test "online SQLite backup includes committed WAL writes and independent restoration is idempotent",
       %{root: root} do
    helper = Application.app_dir(:hermitscale, "priv/app_recipes/python_sqlite_v1/release.py")
    backup = Ecto.UUID.generate()
    recovery = Ecto.UUID.generate()

    program = """
    import json, pathlib, sqlite3, subprocess, sys
    root, helper, backup, recovery = sys.argv[1:]
    data = pathlib.Path(root) / "data"
    data.mkdir()
    (data / "uploads").mkdir()
    (data / "uploads" / "hello.txt").write_text("Customer upload")
    source = sqlite3.connect(str(data / "app.sqlite"))
    source.execute("PRAGMA journal_mode=WAL")
    source.execute("CREATE TABLE sample_records (value TEXT)")
    source.execute("INSERT INTO sample_records VALUES ('Before backup')")
    source.commit()
    assert (data / "app.sqlite-wal").exists()
    def command(action, operation, digest=None):
        args = ["python3", helper, action, "--operation", operation, "--root", root]
        if digest: args += ["--digest", digest]
        return json.loads(subprocess.check_output(args, text=True).splitlines()[-1])
    saved = command("backup", backup)
    assert saved["restoration"] == "verified"
    source.execute("INSERT INTO sample_records VALUES ('After backup')")
    source.commit()
    source.close()
    incoming = pathlib.Path(root) / "incoming"
    (incoming / (recovery + ".backup.tar")).write_bytes((incoming / (backup + ".backup.tar")).read_bytes())
    command("restore", recovery, saved["digest"])
    with sqlite3.connect(str(data / "app.sqlite")) as db:
        assert db.execute("SELECT value FROM sample_records").fetchall() == [("Before backup",)]
        db.execute("INSERT INTO sample_records VALUES ('After recovery')")
        db.commit()
    command("restore", recovery, saved["digest"])
    with sqlite3.connect(str(data / "app.sqlite")) as db:
        assert db.execute("SELECT value FROM sample_records").fetchall() == [("Before backup",), ("After recovery",)]
    assert (data / "uploads" / "hello.txt").read_text() == "Customer upload"
    print("verified")
    """

    assert {"verified\n", 0} =
             System.cmd("python3", ["-c", program, root, helper, backup, recovery],
               stderr_to_stdout: true
             )
  end

  defp recipe!(root, args) do
    {output, 0} = recipe(root, args)
    output |> String.trim() |> String.split("\n") |> List.last() |> Jason.decode!()
  end

  defp recipe(root, args) do
    helper = Application.app_dir(:hermitscale, "priv/app_recipes/python_sqlite_v1/release.py")
    System.cmd("python3", [helper | args] ++ ["--root", root], stderr_to_stdout: true)
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    output
  end
end
