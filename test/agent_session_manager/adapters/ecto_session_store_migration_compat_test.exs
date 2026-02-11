defmodule AgentSessionManager.Adapters.EctoSessionStoreMigrationCompatTest do
  use ExUnit.Case, async: false

  alias AgentSessionManager.Adapters.EctoSessionStore
  alias AgentSessionManager.Adapters.EctoSessionStore.{Migration, MigrationV2}
  alias AgentSessionManager.Core.Error

  defmodule V1OnlyRepo do
    use Ecto.Repo, otp_app: :agent_session_manager, adapter: Ecto.Adapters.SQLite3
  end

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "asm_ecto_migration_compat_#{System.unique_integer([:positive, :monotonic])}.db"
      )

    File.rm(db_path)
    File.rm(db_path <> "-wal")
    File.rm(db_path <> "-shm")

    Application.put_env(:agent_session_manager, V1OnlyRepo,
      database: db_path,
      pool_size: 1
    )

    {:ok, repo_pid} = V1OnlyRepo.start_link()
    Ecto.Migrator.up(V1OnlyRepo, 1, Migration, log: false)

    on_exit(fn ->
      try do
        if Process.alive?(repo_pid), do: Supervisor.stop(repo_pid, :normal)
      catch
        :exit, _ -> :ok
      end

      File.rm(db_path)
      File.rm(db_path <> "-wal")
      File.rm(db_path <> "-shm")
    end)

    :ok
  end

  test "start_link fails with migration_required when only Migration (v1) is applied" do
    assert {:error, %Error{code: :migration_required, message: message}} =
             EctoSessionStore.start_link(repo: V1OnlyRepo)

    assert message =~ "MigrationV2.up()"
  end

  test "start_link succeeds after MigrationV2 is applied" do
    Ecto.Migrator.up(V1OnlyRepo, 2, MigrationV2, log: false)
    assert {:ok, store} = EctoSessionStore.start_link(repo: V1OnlyRepo)
    GenServer.stop(store)
  end
end
