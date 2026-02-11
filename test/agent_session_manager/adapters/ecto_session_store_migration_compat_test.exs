defmodule AgentSessionManager.Adapters.EctoSessionStoreMigrationCompatTest do
  use ExUnit.Case, async: false

  alias AgentSessionManager.Adapters.EctoSessionStore
  alias AgentSessionManager.Adapters.EctoSessionStore.Migration
  alias AgentSessionManager.Core.Error

  defmodule CompatRepo do
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

    Application.put_env(:agent_session_manager, CompatRepo,
      database: db_path,
      pool_size: 1
    )

    {:ok, repo_pid} = CompatRepo.start_link()

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

  test "start_link fails with migration_required when migration has not been applied" do
    assert {:error, %Error{code: :migration_required, message: message}} =
             EctoSessionStore.start_link(repo: CompatRepo)

    assert message =~ "Migration.up()"
  end

  test "start_link succeeds after Migration is applied" do
    Ecto.Migrator.up(CompatRepo, 1, Migration, log: false)
    assert {:ok, store} = EctoSessionStore.start_link(repo: CompatRepo)
    GenServer.stop(store)
  end
end
