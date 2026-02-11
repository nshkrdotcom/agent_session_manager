if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Adapters.AshMaintenanceTest do
    use ExUnit.Case, async: false
    @moduletag :ash

    alias AgentSessionManager.Ash.Adapters.{AshMaintenance, AshSessionStore}
    alias AgentSessionManager.Persistence.RetentionPolicy
    alias AgentSessionManager.Ports.{Maintenance, SessionStore}
    import AgentSessionManager.Test.Fixtures
    alias AgentSessionManager.Ash.TestRepo
    alias Ecto.Adapters.SQL.Sandbox

    setup do
      :ok = Sandbox.checkout(TestRepo)
      maint = {AshMaintenance, AgentSessionManager.Ash.TestDomain}
      store = {AshSessionStore, AgentSessionManager.Ash.TestDomain}
      {:ok, maint: maint, store: store}
    end

    test "execute runs full cycle and returns report shape", %{maint: maint} do
      policy = RetentionPolicy.new(max_completed_session_age_days: 1, hard_delete_after_days: 1)
      assert {:ok, report} = Maintenance.execute(maint, policy)
      assert Map.has_key?(report, :sessions_soft_deleted)
      assert Map.has_key?(report, :sessions_hard_deleted)
      assert Map.has_key?(report, :events_pruned)
      assert Map.has_key?(report, :artifacts_cleaned)
      assert Map.has_key?(report, :orphaned_sequences_cleaned)
      assert is_integer(report.duration_ms)
      assert is_list(report.errors)
    end

    test "soft_delete_expired_sessions respects exempt_statuses and exempt_tags", %{
      maint: maint,
      store: store
    } do
      old = DateTime.add(DateTime.utc_now(), -20, :day)

      deletable =
        build_session(id: "m_soft_1", status: :completed, created_at: old, updated_at: old)

      exempt_by_status =
        build_session(id: "m_soft_2", status: :active, created_at: old, updated_at: old)

      exempt_by_tag =
        build_session(
          id: "m_soft_3",
          status: :completed,
          tags: ["pinned"],
          created_at: old,
          updated_at: old
        )

      :ok = SessionStore.save_session(store, deletable)
      :ok = SessionStore.save_session(store, exempt_by_status)
      :ok = SessionStore.save_session(store, exempt_by_tag)

      policy =
        RetentionPolicy.new(
          max_completed_session_age_days: 1,
          exempt_statuses: [:active],
          exempt_tags: ["pinned"]
        )

      assert {:ok, count} = Maintenance.soft_delete_expired_sessions(maint, policy)
      assert count == 1

      assert {:ok, deleted} = SessionStore.get_session(store, "m_soft_1")
      assert %DateTime{} = deleted.deleted_at

      assert {:ok, still_active} = SessionStore.get_session(store, "m_soft_2")
      assert is_nil(still_active.deleted_at)

      assert {:ok, still_tagged} = SessionStore.get_session(store, "m_soft_3")
      assert is_nil(still_tagged.deleted_at)
    end

    test "hard_delete_expired_sessions removes soft-deleted rows via cascade", %{
      maint: maint,
      store: store
    } do
      old = DateTime.add(DateTime.utc_now(), -10, :day)

      session =
        build_session(id: "m_hard_1", status: :completed, created_at: old, updated_at: old)

      run = build_run(id: "m_hard_run_1", session_id: session.id, status: :completed)

      event =
        build_event(
          id: "m_hard_evt_1",
          type: :run_completed,
          session_id: session.id,
          run_id: run.id
        )

      :ok = SessionStore.save_session(store, session)
      :ok = SessionStore.save_run(store, run)
      {:ok, _} = SessionStore.append_event_with_sequence(store, event)

      stale_deleted =
        %{session | deleted_at: DateTime.add(DateTime.utc_now(), -5, :day)}

      :ok = SessionStore.save_session(store, stale_deleted)
      policy = RetentionPolicy.new(hard_delete_after_days: 1)

      assert {:ok, hard_count} = Maintenance.hard_delete_expired_sessions(maint, policy)
      assert hard_count == 1

      assert {:error, _} = SessionStore.get_session(store, session.id)
      assert {:error, _} = SessionStore.get_run(store, run.id)
      assert {:ok, []} = SessionStore.get_events(store, session.id)
    end

    test "prune_session_events prunes low-priority events first and keeps protected types", %{
      maint: maint,
      store: store
    } do
      session = build_session(id: "m_prune_1")
      :ok = SessionStore.save_session(store, session)

      seed = [
        build_event(id: "m_p_1", type: :session_created, session_id: session.id),
        build_event(id: "m_p_2", type: :message_streamed, session_id: session.id),
        build_event(id: "m_p_3", type: :message_streamed, session_id: session.id),
        build_event(id: "m_p_4", type: :run_started, session_id: session.id),
        build_event(id: "m_p_5", type: :message_received, session_id: session.id),
        build_event(id: "m_p_6", type: :message_received, session_id: session.id),
        build_event(id: "m_p_7", type: :run_completed, session_id: session.id)
      ]

      {:ok, _} = SessionStore.append_events(store, seed)

      policy = RetentionPolicy.new(max_events_per_session: 3)
      assert {:ok, pruned} = Maintenance.prune_session_events(maint, session.id, policy)
      assert pruned == 4

      assert {:ok, remaining} = SessionStore.get_events(store, session.id)
      remaining_types = Enum.map(remaining, & &1.type)
      assert :session_created in remaining_types
      assert :run_started in remaining_types
      assert :run_completed in remaining_types
    end

    test "clean_orphaned_artifacts removes artifacts with missing session references", %{
      maint: maint
    } do
      # Constraints prevent creating orphans in normal operation.
      # Temporarily drop FK inside sandbox transaction to simulate legacy orphan rows.
      TestRepo.query!(
        "ALTER TABLE asm_artifacts DROP CONSTRAINT IF EXISTS asm_artifacts_session_id_fkey"
      )

      TestRepo.query!(
        """
        INSERT INTO asm_artifacts
          (id, session_id, run_id, key, content_type, byte_size, checksum_sha256,
           storage_backend, storage_ref, metadata, created_at, deleted_at)
        VALUES
          ($1, $2, NULL, $3, $4, $5, $6, $7, $8, $9, $10, NULL)
        """,
        [
          "m_orphan_artifact_1",
          "missing_session",
          "artifact/orphan/1",
          "application/json",
          10,
          String.duplicate("c", 64),
          "s3",
          "s3://bucket/orphan",
          "{}",
          DateTime.utc_now()
        ]
      )

      assert {:ok, cleaned} = Maintenance.clean_orphaned_artifacts(maint)
      assert cleaned == 1
    end

    test "health_check reports sequence mismatches", %{maint: maint, store: store} do
      session = build_session(id: "m_health_1")
      :ok = SessionStore.save_session(store, session)

      {:ok, _} =
        SessionStore.append_events(store, [
          build_event(id: "m_h_1", type: :session_created, session_id: session.id),
          build_event(id: "m_h_2", type: :session_started, session_id: session.id)
        ])

      # Force mismatch: set counter lower than max(sequence_number)
      TestRepo.query!(
        "UPDATE asm_session_sequences SET last_sequence = 1 WHERE session_id = $1",
        [session.id]
      )

      assert {:ok, issues} = Maintenance.health_check(maint)
      assert Enum.any?(issues, &String.contains?(&1, "Sequence mismatch for #{session.id}"))
    end
  end
end
