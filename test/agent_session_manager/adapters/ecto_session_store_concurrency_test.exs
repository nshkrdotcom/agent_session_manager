defmodule AgentSessionManager.Adapters.EctoSessionStoreConcurrencyTest do
  @moduledoc """
  Concurrency coverage for EctoSessionStore sequence assignment.
  """

  use AgentSessionManager.SupertesterCase, async: false

  alias AgentSessionManager.Adapters.EctoSessionStore
  alias AgentSessionManager.Adapters.EctoSessionStore.Migration

  alias AgentSessionManager.Adapters.EctoSessionStore.Schemas.{
    EventSchema,
    RunSchema,
    SessionSchema,
    SessionSequenceSchema
  }

  alias AgentSessionManager.Core.{Event, Run, Session}
  alias AgentSessionManager.Ports.SessionStore

  defmodule ConcurrencyRepo do
    use Ecto.Repo,
      otp_app: :agent_session_manager,
      adapter: Ecto.Adapters.SQLite3
  end

  @db_path Path.join(System.tmp_dir!(), "asm_ecto_concurrency_test.db")

  setup_all do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")

    Application.put_env(:agent_session_manager, ConcurrencyRepo,
      database: @db_path,
      pool_size: 1,
      busy_timeout: 15_000
    )

    {:ok, repo_pid} = ConcurrencyRepo.start_link()
    Ecto.Migrator.up(ConcurrencyRepo, 1, Migration, log: false)

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
    ConcurrencyRepo.delete_all(EventSchema)
    ConcurrencyRepo.delete_all(SessionSequenceSchema)
    ConcurrencyRepo.delete_all(RunSchema)
    ConcurrencyRepo.delete_all(SessionSchema)

    {:ok, session} = Session.new(%{id: "ses_concurrency", agent_id: "agent-concurrency"})
    :ok = SessionStore.save_session({EctoSessionStore, ConcurrencyRepo}, session)

    {:ok, run} = Run.new(%{id: "run_concurrency", session_id: session.id})
    :ok = SessionStore.save_run({EctoSessionStore, ConcurrencyRepo}, run)

    %{store: {EctoSessionStore, ConcurrencyRepo}, session: session, run: run}
  end

  describe "append_event_with_sequence/2 under contention" do
    test "assigns unique contiguous sequence numbers", %{store: store, session: session, run: run} do
      total = 50

      results =
        run_concurrent(
          total,
          fn index ->
            {:ok, event} =
              Event.new(%{
                id: "evt_seq_#{index}",
                type: :message_received,
                session_id: session.id,
                run_id: run.id,
                data: %{index: index}
              })

            SessionStore.append_event_with_sequence(store, event)
          end,
          20_000
        )

      assert Enum.all?(results, &match?({:ok, %Event{}}, &1))

      assigned =
        results
        |> Enum.map(fn {:ok, event} -> event.sequence_number end)
        |> Enum.sort()

      assert assigned == Enum.to_list(1..total)
      assert {:ok, ^total} = SessionStore.get_latest_sequence(store, session.id)
    end
  end

  describe "append_events/2 under contention" do
    test "preserves uniqueness and monotonicity across concurrent batches", %{
      store: store,
      session: session,
      run: run
    } do
      workers = 10
      per_worker = 5

      batch_results =
        run_concurrent(
          workers,
          fn worker ->
            events =
              for offset <- 1..per_worker do
                event_index = worker * 100 + offset

                {:ok, event} =
                  Event.new(%{
                    id: "evt_batch_#{worker}_#{offset}",
                    type: :message_received,
                    session_id: session.id,
                    run_id: run.id,
                    data: %{worker: worker, offset: offset, index: event_index}
                  })

                event
              end

            SessionStore.append_events(store, events)
          end,
          20_000
        )

      assert Enum.all?(batch_results, &match?({:ok, _events}, &1))

      total = workers * per_worker
      assert {:ok, persisted} = SessionStore.get_events(store, session.id)
      assert length(persisted) == total

      sequences = Enum.map(persisted, & &1.sequence_number)
      assert sequences == Enum.to_list(1..total)
      assert {:ok, ^total} = SessionStore.get_latest_sequence(store, session.id)
    end
  end
end
