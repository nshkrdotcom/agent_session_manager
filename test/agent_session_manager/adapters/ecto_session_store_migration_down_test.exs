defmodule AgentSessionManager.Adapters.EctoSessionStoreMigrationDownTest do
  use ExUnit.Case, async: false

  alias AgentSessionManager.Adapters.EctoSessionStore.{Migration, MigrationV2}
  alias Ecto.Adapters.SQL

  defmodule MigrationDownRepo do
    use Ecto.Repo, otp_app: :agent_session_manager, adapter: Ecto.Adapters.SQLite3
  end

  @db_path Path.join(System.tmp_dir!(), "asm_migration_down_test.db")

  setup_all do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")

    Application.put_env(:agent_session_manager, MigrationDownRepo,
      database: @db_path,
      pool_size: 1
    )

    {:ok, repo_pid} = MigrationDownRepo.start_link()

    on_exit(fn ->
      try do
        if Process.alive?(repo_pid), do: Supervisor.stop(repo_pid, :normal)
      catch
        :exit, _ -> :ok
      end

      File.rm(@db_path)
      File.rm(@db_path <> "-wal")
      File.rm(@db_path <> "-shm")
    end)

    :ok
  end

  setup do
    Ecto.Migrator.up(MigrationDownRepo, 1, Migration, log: false)
    Ecto.Migrator.up(MigrationDownRepo, 2, MigrationV2, log: false)
    :ok
  end

  test "MigrationV2.down drops artifacts table and v2 indexes on SQLite" do
    assert table_exists?("asm_artifacts")
    assert index_exists?("asm_artifacts_key_index")
    assert index_exists?("asm_artifacts_session_id_index")
    assert index_exists?("asm_events_correlation_id_index")

    :ok = Ecto.Migrator.down(MigrationDownRepo, 2, MigrationV2, log: false)

    refute table_exists?("asm_artifacts")
    refute index_exists?("asm_artifacts_key_index")
    refute index_exists?("asm_artifacts_session_id_index")
    refute index_exists?("asm_events_correlation_id_index")

    # SQLite keeps added columns after down/0 (drop column unsupported).
    assert column_exists?("asm_sessions", "deleted_at")
  end

  defp table_exists?(table_name) do
    sql = """
    SELECT 1 FROM sqlite_master
    WHERE type = 'table' AND name = ? LIMIT 1
    """

    case SQL.query(MigrationDownRepo, sql, [table_name]) do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  end

  defp index_exists?(index_name) do
    sql = """
    SELECT 1 FROM sqlite_master
    WHERE type = 'index' AND name = ? LIMIT 1
    """

    case SQL.query(MigrationDownRepo, sql, [index_name]) do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  end

  defp column_exists?(table_name, column_name) do
    table_name
    |> table_columns()
    |> Enum.member?(column_name)
  end

  defp table_columns(table_name) do
    sql = "PRAGMA table_info(#{table_name})"

    case SQL.query(MigrationDownRepo, sql, []) do
      {:ok, %{rows: rows}} -> Enum.flat_map(rows, &extract_column_name/1)
      _ -> []
    end
  end

  defp extract_column_name([_cid, name | _rest]), do: [name]
  defp extract_column_name(_row), do: []
end
