defmodule AgentSessionManager.Adapters.EctoMaintenanceTest do
  use ExUnit.Case, async: false

  alias AgentSessionManager.Adapters.{EctoMaintenance, EctoSessionStore}
  alias AgentSessionManager.Adapters.EctoSessionStore.Migration
  alias AgentSessionManager.Adapters.EctoSessionStore.MigrationV2
  alias AgentSessionManager.Core.{Event, Session}
  alias AgentSessionManager.Persistence.RetentionPolicy
  alias AgentSessionManager.Ports.{Maintenance, SessionStore}

  defmodule MaintTestRepo do
    use Ecto.Repo, otp_app: :agent_session_manager, adapter: Ecto.Adapters.SQLite3
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
  end

  # ============================================================================
  # health_check
  # ============================================================================

  describe "health_check/1" do
    test "returns empty list for healthy data", %{store: store, maint: maint} do
      seed_session(store, "ses_healthy")
      seed_event(store, "ses_healthy", :run_started)

      {:ok, issues} = Maintenance.health_check(maint)
      assert is_list(issues)
    end
  end
end
