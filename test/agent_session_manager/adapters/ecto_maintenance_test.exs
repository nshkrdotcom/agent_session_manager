defmodule AgentSessionManager.Adapters.EctoMaintenanceTest do
  use ExUnit.Case, async: false

  alias AgentSessionManager.Adapters.{EctoMaintenance, EctoSessionStore}
  alias AgentSessionManager.Adapters.EctoSessionStore.Migration
  alias AgentSessionManager.Adapters.EctoSessionStore.MigrationV2

  alias AgentSessionManager.Adapters.EctoSessionStore.Schemas.{
    ArtifactSchema,
    EventSchema,
    RunSchema,
    SessionSequenceSchema
  }

  alias AgentSessionManager.Core.{Event, Run, Session}
  alias AgentSessionManager.Persistence.RetentionPolicy
  alias AgentSessionManager.Ports.{Maintenance, SessionStore}

  defmodule MaintTestRepo do
    use Ecto.Repo, otp_app: :agent_session_manager, adapter: Ecto.Adapters.SQLite3
  end

  defmodule RepoCrashAfterFirstDelete do
    @real AgentSessionManager.Adapters.EctoMaintenanceTest.MaintTestRepo

    def transaction(fun), do: @real.transaction(fun)
    def all(query), do: @real.all(query)

    def delete_all(query) do
      key = {__MODULE__, :delete_count}
      delete_count = Process.get(key, 0)
      Process.put(key, delete_count + 1)

      if delete_count == 0 do
        @real.delete_all(query)
      else
        raise "simulated delete failure"
      end
    end
  end

  @db_path Path.join(System.tmp_dir!(), "asm_maintenance_test.db")

  setup_all do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")

    Application.put_env(:agent_session_manager, MaintTestRepo,
      database: @db_path,
      pool_size: 1
    )

    {:ok, repo_pid} = MaintTestRepo.start_link()
    Ecto.Migrator.up(MaintTestRepo, 1, Migration, log: false)
    Ecto.Migrator.up(MaintTestRepo, 2, MigrationV2, log: false)

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
    MaintTestRepo.delete_all(AgentSessionManager.Adapters.EctoSessionStore.Schemas.EventSchema)
    MaintTestRepo.delete_all(AgentSessionManager.Adapters.EctoSessionStore.Schemas.RunSchema)
    MaintTestRepo.delete_all(AgentSessionManager.Adapters.EctoSessionStore.Schemas.ArtifactSchema)

    MaintTestRepo.delete_all(
      AgentSessionManager.Adapters.EctoSessionStore.Schemas.SessionSequenceSchema
    )

    MaintTestRepo.delete_all(AgentSessionManager.Adapters.EctoSessionStore.Schemas.SessionSchema)

    {:ok, store} = EctoSessionStore.start_link(repo: MaintTestRepo)
    %{store: store, maint: {EctoMaintenance, MaintTestRepo}}
  end

  defp seed_session(store, id, opts \\ []) do
    status = Keyword.get(opts, :status, :completed)
    tags = Keyword.get(opts, :tags, [])

    {:ok, session} = Session.new(%{id: id, agent_id: "agent-1", tags: tags})
    session = %{session | status: status}

    :ok = SessionStore.save_session(store, session)
    session
  end

  defp seed_old_session(store, id, days_ago, opts) do
    session = seed_session(store, id, opts)

    old_time =
      DateTime.utc_now()
      |> DateTime.add(-days_ago, :day)
      |> DateTime.truncate(:microsecond)

    old_session = %{session | created_at: old_time, updated_at: old_time}
    :ok = SessionStore.save_session(store, old_session)
    old_session
  end

  defp seed_event(store, session_id, type) do
    {:ok, event} =
      Event.new(%{type: type, session_id: session_id, run_id: "run_1"})

    {:ok, _} = SessionStore.append_event_with_sequence(store, event)
  end

  # ============================================================================
  # execute
  # ============================================================================

  describe "execute/2" do
    test "returns a report with all fields", %{maint: maint} do
      policy = RetentionPolicy.new()
      {:ok, report} = Maintenance.execute(maint, policy)

      assert is_integer(report.sessions_soft_deleted)
      assert is_integer(report.sessions_hard_deleted)
      assert is_integer(report.events_pruned)
      assert is_integer(report.artifacts_cleaned)
      assert is_integer(report.orphaned_sequences_cleaned)
      assert is_integer(report.duration_ms)
      assert is_list(report.errors)
    end

    test "rejects invalid policy", %{maint: maint} do
      policy = RetentionPolicy.new(batch_size: 0)
      {:error, error} = Maintenance.execute(maint, policy)
      assert error.code == :validation_error
    end
  end

  # ============================================================================
  # soft_delete_expired_sessions
  # ============================================================================

  describe "soft_delete_expired_sessions/2" do
    test "soft-deletes old completed sessions", %{store: store, maint: maint} do
      seed_old_session(store, "ses_old", 100, status: :completed)
      seed_session(store, "ses_new", status: :completed)

      policy = RetentionPolicy.new(max_completed_session_age_days: 90)
      {:ok, count} = Maintenance.soft_delete_expired_sessions(maint, policy)
      assert count == 1

      {:ok, session} = SessionStore.get_session(store, "ses_old")
      assert session.deleted_at != nil
    end

    test "skips sessions with exempt status", %{store: store, maint: maint} do
      seed_old_session(store, "ses_active", 100, status: :active)

      policy = RetentionPolicy.new(max_completed_session_age_days: 90)
      {:ok, count} = Maintenance.soft_delete_expired_sessions(maint, policy)
      assert count == 0
    end

    test "skips sessions with exempt tags", %{store: store, maint: maint} do
      seed_old_session(store, "ses_pinned", 100, status: :completed, tags: ["pinned"])

      policy = RetentionPolicy.new(max_completed_session_age_days: 90)
      {:ok, count} = Maintenance.soft_delete_expired_sessions(maint, policy)
      assert count == 0
    end

    test "returns 0 when policy is infinity", %{maint: maint} do
      policy = RetentionPolicy.new(max_completed_session_age_days: :infinity)
      {:ok, 0} = Maintenance.soft_delete_expired_sessions(maint, policy)
    end

    test "uses updated_at as completion proxy for retention cutoff", %{store: store, maint: maint} do
      session = seed_old_session(store, "ses_recently_updated", 120, status: :completed)
      recent_update = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      :ok = SessionStore.save_session(store, %{session | updated_at: recent_update})

      policy = RetentionPolicy.new(max_completed_session_age_days: 90)
      {:ok, count} = Maintenance.soft_delete_expired_sessions(maint, policy)
      assert count == 0

      {:ok, refreshed} = SessionStore.get_session(store, "ses_recently_updated")
      assert is_nil(refreshed.deleted_at)
    end
  end

  # ============================================================================
  # hard_delete_expired_sessions
  # ============================================================================

  describe "hard_delete_expired_sessions/2" do
    test "hard-deletes sessions soft-deleted long ago", %{store: store, maint: maint} do
      session = seed_session(store, "ses_del", status: :completed)

      old_deleted_at =
        DateTime.utc_now()
        |> DateTime.add(-60, :day)
        |> DateTime.truncate(:microsecond)

      deleted_session = %{session | deleted_at: old_deleted_at}
      :ok = SessionStore.save_session(store, deleted_session)

      seed_event(store, "ses_del", :run_started)

      policy = RetentionPolicy.new(hard_delete_after_days: 30)
      {:ok, count} = Maintenance.hard_delete_expired_sessions(maint, policy)
      assert count == 1

      {:error, _} = SessionStore.get_session(store, "ses_del")
    end

    test "returns 0 when policy is infinity", %{maint: maint} do
      policy = RetentionPolicy.new(hard_delete_after_days: :infinity)
      {:ok, 0} = Maintenance.hard_delete_expired_sessions(maint, policy)
    end

    test "rolls back all deletes when one delete in the cascade fails", %{store: store} do
      session = seed_session(store, "ses_txn", status: :completed)

      old_deleted_at =
        DateTime.utc_now()
        |> DateTime.add(-60, :day)
        |> DateTime.truncate(:microsecond)

      :ok = SessionStore.save_session(store, %{session | deleted_at: old_deleted_at})

      {:ok, run} = Run.new(%{id: "run_txn", session_id: session.id})
      :ok = SessionStore.save_run(store, run)

      seed_event(store, session.id, :run_started)

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      MaintTestRepo.insert!(%ArtifactSchema{
        id: "art_txn",
        session_id: session.id,
        run_id: run.id,
        key: "artifacts/#{session.id}",
        content_type: "application/octet-stream",
        byte_size: 10,
        checksum_sha256: String.duplicate("b", 64),
        storage_backend: "file",
        storage_ref: "file:///tmp/art_txn",
        metadata: %{},
        created_at: now
      })

      Process.put({RepoCrashAfterFirstDelete, :delete_count}, 0)

      maint = {EctoMaintenance, RepoCrashAfterFirstDelete}
      policy = RetentionPolicy.new(hard_delete_after_days: 30)

      assert {:error, _} = Maintenance.hard_delete_expired_sessions(maint, policy)

      assert MaintTestRepo.aggregate(EventSchema, :count, :id) == 1
      assert MaintTestRepo.aggregate(RunSchema, :count, :id) == 1
      assert MaintTestRepo.aggregate(ArtifactSchema, :count, :id) == 1
      assert MaintTestRepo.aggregate(SessionSequenceSchema, :count, :session_id) == 1
    end
  end

  # ============================================================================
  # prune_session_events
  # ============================================================================

  describe "prune_session_events/3" do
    test "prunes events when over limit", %{store: store, maint: maint} do
      seed_session(store, "ses_big")

      for _ <- 1..10 do
        seed_event(store, "ses_big", :message_streamed)
      end

      policy = RetentionPolicy.new(max_events_per_session: 5)
      {:ok, pruned} = Maintenance.prune_session_events(maint, "ses_big", policy)
      assert pruned == 5
    end

    test "returns 0 when under limit", %{store: store, maint: maint} do
      seed_session(store, "ses_small")
      seed_event(store, "ses_small", :run_started)

      policy = RetentionPolicy.new(max_events_per_session: 100)
      {:ok, 0} = Maintenance.prune_session_events(maint, "ses_small", policy)
    end

    test "returns 0 when limit is infinity", %{store: store, maint: maint} do
      seed_session(store, "ses_inf")
      seed_event(store, "ses_inf", :run_started)

      policy = RetentionPolicy.new(max_events_per_session: :infinity)
      {:ok, 0} = Maintenance.prune_session_events(maint, "ses_inf", policy)
    end

    test "preserves run_started and run_completed while pruning oldest events", %{
      store: store,
      maint: maint
    } do
      seed_session(store, "ses_keep_boundary_events")
      seed_event(store, "ses_keep_boundary_events", :run_started)
      seed_event(store, "ses_keep_boundary_events", :message_received)
      seed_event(store, "ses_keep_boundary_events", :tool_call_started)
      seed_event(store, "ses_keep_boundary_events", :message_streamed)
      seed_event(store, "ses_keep_boundary_events", :run_completed)

      policy = RetentionPolicy.new(max_events_per_session: 2)
      {:ok, pruned} = Maintenance.prune_session_events(maint, "ses_keep_boundary_events", policy)
      assert pruned > 0

      {:ok, remaining} = SessionStore.get_events(store, "ses_keep_boundary_events")
      remaining_types = Enum.map(remaining, & &1.type)

      assert :run_started in remaining_types
      assert :run_completed in remaining_types
    end
  end

  # ============================================================================
  # health_check
  # ============================================================================

  describe "health_check/1" do
    test "returns empty list for healthy data", %{store: store, maint: maint} do
      seed_session(store, "ses_healthy")
      seed_event(store, "ses_healthy", :run_started)

      {:ok, issues} = Maintenance.health_check(maint)
      assert issues == []
    end

    test "does not report sequence mismatch after event pruning", %{store: store, maint: maint} do
      seed_session(store, "ses_pruned")

      for _ <- 1..8 do
        seed_event(store, "ses_pruned", :message_streamed)
      end

      prune_policy = RetentionPolicy.new(max_events_per_session: 3)
      {:ok, pruned} = Maintenance.prune_session_events(maint, "ses_pruned", prune_policy)
      assert pruned > 0

      {:ok, issues} = Maintenance.health_check(maint)
      assert issues == []
    end
  end
end
