defmodule AgentSessionManager.Ports.SessionStoreContractMultiImplTest do
  @moduledoc """
  SessionStore contract cases executed across multiple implementations.
  """

  use AgentSessionManager.SupertesterCase, async: false

  alias AgentSessionManager.Adapters.{EctoSessionStore, InMemorySessionStore}
  alias AgentSessionManager.Adapters.EctoSessionStore.{Migration, MigrationV2}

  alias AgentSessionManager.Adapters.EctoSessionStore.Schemas.{
    EventSchema,
    RunSchema,
    SessionSchema,
    SessionSequenceSchema
  }

  alias AgentSessionManager.Core.{Event, Run, Session}
  alias AgentSessionManager.Ports.SessionStore

  defmodule ContractRepo do
    use Ecto.Repo, otp_app: :agent_session_manager, adapter: Ecto.Adapters.SQLite3
  end

  @db_path Path.join(System.tmp_dir!(), "asm_session_store_contract_multi_impl.db")

  setup_all do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")

    Application.put_env(:agent_session_manager, ContractRepo,
      database: @db_path,
      pool_size: 1
    )

    {:ok, repo_pid} = ContractRepo.start_link()
    Ecto.Migrator.up(ContractRepo, 1, Migration, log: false)
    Ecto.Migrator.up(ContractRepo, 2, MigrationV2, log: false)

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
    ContractRepo.delete_all(EventSchema)
    ContractRepo.delete_all(SessionSequenceSchema)
    ContractRepo.delete_all(RunSchema)
    ContractRepo.delete_all(SessionSchema)
    :ok
  end

  describe "contract parity" do
    test "session CRUD works across implementations" do
      each_store(fn label, store ->
        {:ok, session} = Session.new(%{id: "ses_contract_#{label}", agent_id: "agent-#{label}"})

        assert :ok = SessionStore.save_session(store, session)
        assert {:ok, fetched} = SessionStore.get_session(store, session.id)
        assert fetched.id == session.id

        assert :ok = SessionStore.delete_session(store, session.id)
        assert {:error, _error} = SessionStore.get_session(store, session.id)
      end)
    end

    test "run lifecycle reads and writes are consistent across implementations" do
      each_store(fn label, store ->
        {:ok, session} = Session.new(%{id: "ses_runs_#{label}", agent_id: "agent-runs-#{label}"})
        :ok = SessionStore.save_session(store, session)

        {:ok, run} = Run.new(%{id: "run_contract_#{label}", session_id: session.id})
        :ok = SessionStore.save_run(store, run)

        {:ok, running} = Run.update_status(run, :running)
        :ok = SessionStore.save_run(store, running)

        assert {:ok, fetched} = SessionStore.get_run(store, run.id)
        assert fetched.status == :running

        assert {:ok, active} = SessionStore.get_active_run(store, session.id)
        assert active.id == run.id
      end)
    end

    test "event append semantics are consistent across implementations" do
      each_store(fn label, store ->
        {:ok, session} =
          Session.new(%{id: "ses_events_#{label}", agent_id: "agent-events-#{label}"})

        :ok = SessionStore.save_session(store, session)

        {:ok, run} = Run.new(%{id: "run_events_#{label}", session_id: session.id})
        :ok = SessionStore.save_run(store, run)

        {:ok, e1} =
          Event.new(%{
            id: "evt_contract_#{label}_1",
            type: :run_started,
            session_id: session.id,
            run_id: run.id
          })

        {:ok, e2} =
          Event.new(%{
            id: "evt_contract_#{label}_2",
            type: :message_received,
            session_id: session.id,
            run_id: run.id
          })

        assert {:ok, s1} = SessionStore.append_event_with_sequence(store, e1)
        assert {:ok, s2} = SessionStore.append_event_with_sequence(store, e2)
        assert s1.sequence_number == 1
        assert s2.sequence_number == 2

        assert {:ok, events} = SessionStore.get_events(store, session.id)
        assert Enum.map(events, & &1.id) == [e1.id, e2.id]
      end)
    end

    test "flush/2 atomically persists execution payload across implementations" do
      each_store(fn label, store ->
        {:ok, session} =
          Session.new(%{id: "ses_flush_#{label}", agent_id: "agent-flush-#{label}"})

        {:ok, run} = Run.new(%{id: "run_flush_#{label}", session_id: session.id})

        {:ok, event} =
          Event.new(%{
            id: "evt_flush_#{label}",
            type: :run_completed,
            session_id: session.id,
            run_id: run.id,
            data: %{ok: true}
          })

        payload = %{session: session, run: run, events: [event]}
        assert :ok = SessionStore.flush(store, payload)

        assert {:ok, stored_session} = SessionStore.get_session(store, session.id)
        assert stored_session.id == session.id
        assert {:ok, stored_run} = SessionStore.get_run(store, run.id)
        assert stored_run.id == run.id
        assert {:ok, [stored_event]} = SessionStore.get_events(store, session.id)
        assert stored_event.id == event.id
      end)
    end
  end

  defp each_store(fun) when is_function(fun, 2) do
    {:ok, in_memory_store} = InMemorySessionStore.start_link([])
    cleanup_on_exit(fn -> safe_stop(in_memory_store) end)

    fun.("in_memory", in_memory_store)
    fun.("ecto_module_ref", {EctoSessionStore, ContractRepo})
  end
end
