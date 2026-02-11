if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Adapters.AshMaintenanceTest do
    use ExUnit.Case, async: false

    alias AgentSessionManager.Ash.Adapters.{AshMaintenance, AshSessionStore}
    alias AgentSessionManager.Persistence.RetentionPolicy
    alias AgentSessionManager.Ports.{Maintenance, SessionStore}
    import AgentSessionManager.Test.Fixtures

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(AgentSessionManager.Ash.TestRepo)
      maint = {AshMaintenance, AgentSessionManager.Ash.TestDomain}
      store = {AshSessionStore, AgentSessionManager.Ash.TestDomain}
      {:ok, maint: maint, store: store}
    end

    test "execute returns maintenance report", %{maint: maint} do
      policy = RetentionPolicy.new(max_completed_session_age_days: 1, hard_delete_after_days: 1)
      assert {:ok, report} = Maintenance.execute(maint, policy)
      assert Map.has_key?(report, :duration_ms)
      assert Map.has_key?(report, :errors)
    end

    test "soft delete + hard delete + health check", %{maint: maint, store: store} do
      old = DateTime.add(DateTime.utc_now(), -10, :day)
      session = build_session(id: "m_s_1", status: :completed, created_at: old, updated_at: old)
      :ok = SessionStore.save_session(store, session)

      policy = RetentionPolicy.new(max_completed_session_age_days: 1, hard_delete_after_days: 1)
      assert {:ok, soft_count} = Maintenance.soft_delete_expired_sessions(maint, policy)
      assert soft_count >= 1

      stale = %{session | deleted_at: DateTime.add(DateTime.utc_now(), -2, :day)}
      :ok = SessionStore.save_session(store, stale)

      assert {:ok, hard_count} = Maintenance.hard_delete_expired_sessions(maint, policy)
      assert hard_count >= 1

      assert {:ok, issues} = Maintenance.health_check(maint)
      assert is_list(issues)
    end

    test "prune session events and clean orphaned artifacts", %{maint: maint, store: store} do
      session = build_session(id: "m_s_2")
      :ok = SessionStore.save_session(store, session)

      events =
        for i <- 1..8 do
          build_event(id: "m_e_#{i}", type: :message_streamed, session_id: session.id)
        end

      {:ok, _} = SessionStore.append_events(store, events)

      policy = RetentionPolicy.new(max_events_per_session: 3)
      assert {:ok, pruned} = Maintenance.prune_session_events(maint, session.id, policy)
      assert pruned >= 1

      assert {:ok, cleaned} = Maintenance.clean_orphaned_artifacts(maint)
      assert is_integer(cleaned)
    end
  end
end
