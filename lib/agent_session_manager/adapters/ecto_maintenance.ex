if Code.ensure_loaded?(Ecto.Query) do
  defmodule AgentSessionManager.Adapters.EctoMaintenance do
    @moduledoc """
    Ecto-based implementation of the `Maintenance` port.

    Handles retention enforcement, event pruning, hard deletion,
    and data integrity checks using Ecto queries.

    ## Usage

        maint = {EctoMaintenance, MyApp.Repo}
        policy = RetentionPolicy.new(max_completed_session_age_days: 90)
        {:ok, report} = Maintenance.execute(maint, policy)

    """

    import Ecto.Query

    @behaviour AgentSessionManager.Ports.Maintenance

    alias AgentSessionManager.Core.Error
    alias AgentSessionManager.Persistence.RetentionPolicy
    alias AgentSessionManager.Ports.Maintenance

    alias AgentSessionManager.Adapters.EctoSessionStore.Schemas.{
      ArtifactSchema,
      EventSchema,
      RunSchema,
      SessionSchema,
      SessionSequenceSchema
    }

    # ============================================================================
    # Maintenance callbacks
    # ============================================================================

    @impl Maintenance
    def execute(repo, policy), do: do_execute(repo, policy)

    @impl Maintenance
    def prune_session_events(repo, session_id, policy),
      do: do_prune_session_events(repo, session_id, policy)

    @impl Maintenance
    def soft_delete_expired_sessions(repo, policy), do: do_soft_delete_expired(repo, policy)

    @impl Maintenance
    def hard_delete_expired_sessions(repo, policy), do: do_hard_delete_expired(repo, policy)

    @impl Maintenance
    def clean_orphaned_artifacts(repo, _opts \\ []), do: do_clean_orphaned_artifacts(repo)

    @impl Maintenance
    def health_check(repo), do: do_health_check(repo)

    # ============================================================================
    # Execute (full maintenance cycle)
    # ============================================================================

    defp do_execute(repo, %RetentionPolicy{} = policy) do
      case RetentionPolicy.validate(policy) do
        {:error, reason} ->
          {:error, Error.new(:validation_error, reason)}

        :ok ->
          start_time = System.monotonic_time(:millisecond)
          errors = []

          {soft_deleted, errors} = safe_op(fn -> do_soft_delete_expired(repo, policy) end, errors)
          {hard_deleted, errors} = safe_op(fn -> do_hard_delete_expired(repo, policy) end, errors)
          {events_pruned, errors} = safe_op(fn -> do_prune_all_sessions(repo, policy) end, errors)

          {artifacts_cleaned, errors} =
            safe_op(fn -> do_clean_orphaned_artifacts(repo) end, errors)

          {orphans_cleaned, errors} =
            safe_op(fn -> do_clean_orphaned_sequences(repo) end, errors)

          duration_ms = System.monotonic_time(:millisecond) - start_time

          emit_maintenance_telemetry(duration_ms)

          {:ok,
           %{
             sessions_soft_deleted: soft_deleted,
             sessions_hard_deleted: hard_deleted,
             events_pruned: events_pruned,
             artifacts_cleaned: artifacts_cleaned,
             orphaned_sequences_cleaned: orphans_cleaned,
             duration_ms: duration_ms,
             errors: errors
           }}
      end
    end

    defp safe_op(func, errors) do
      case func.() do
        {:ok, count} -> {count, errors}
        {:error, %Error{message: msg}} -> {0, errors ++ [msg]}
        {:error, msg} -> {0, errors ++ [inspect(msg)]}
      end
    end

    # ============================================================================
    # Soft delete expired sessions
    # ============================================================================

    defp do_soft_delete_expired(repo, %RetentionPolicy{} = policy) do
      if policy.max_completed_session_age_days == :infinity do
        {:ok, 0}
      else
        cutoff =
          DateTime.utc_now()
          |> DateTime.add(-policy.max_completed_session_age_days, :day)

        exempt_statuses = Enum.map(policy.exempt_statuses, &to_string/1)

        query =
          from(s in SessionSchema,
            where: is_nil(s.deleted_at),
            where: s.status not in ^exempt_statuses,
            where: s.updated_at < ^cutoff
          )

        # Filter out exempt tags in Elixir (SQLite array compat)
        sessions = repo.all(query)

        to_delete =
          Enum.reject(sessions, fn s ->
            tags = s.tags || []
            Enum.any?(policy.exempt_tags, &(&1 in tags))
          end)

        now = DateTime.utc_now()

        count =
          Enum.count(to_delete, fn s ->
            repo.update_all(
              from(ss in SessionSchema, where: ss.id == ^s.id),
              set: [deleted_at: now]
            )

            true
          end)

        {:ok, count}
      end
    rescue
      e -> {:error, Error.new(:maintenance_error, Exception.message(e))}
    end

    # ============================================================================
    # Hard delete expired sessions
    # ============================================================================

    defp do_hard_delete_expired(repo, %RetentionPolicy{} = policy) do
      if policy.hard_delete_after_days == :infinity do
        {:ok, 0}
      else
        cutoff =
          DateTime.utc_now()
          |> DateTime.add(-policy.hard_delete_after_days, :day)

        sessions =
          repo.all(
            from(s in SessionSchema,
              where: not is_nil(s.deleted_at),
              where: s.deleted_at < ^cutoff,
              select: s.id
            )
          )

        delete_hard_expired_sessions(repo, sessions)
      end
    rescue
      e -> {:error, Error.new(:maintenance_error, Exception.message(e))}
    end

    defp delete_hard_expired_sessions(repo, session_ids) do
      Enum.reduce_while(session_ids, {:ok, 0}, fn session_id, {:ok, deleted_count} ->
        case delete_session_cascade(repo, session_id) do
          :ok ->
            {:cont, {:ok, deleted_count + 1}}

          {:error, %Error{} = error} ->
            {:halt, {:error, error}}
        end
      end)
    end

    defp delete_session_cascade(repo, session_id) do
      case repo.transaction(fn ->
             repo.delete_all(from(e in EventSchema, where: e.session_id == ^session_id))
             repo.delete_all(from(r in RunSchema, where: r.session_id == ^session_id))
             repo.delete_all(from(a in ArtifactSchema, where: a.session_id == ^session_id))

             repo.delete_all(
               from(sq in SessionSequenceSchema, where: sq.session_id == ^session_id)
             )

             repo.delete_all(from(s in SessionSchema, where: s.id == ^session_id))
           end) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, Error.new(:maintenance_error, inspect(reason))}
      end
    end

    # ============================================================================
    # Prune events
    # ============================================================================

    defp do_prune_all_sessions(repo, %RetentionPolicy{} = policy) do
      if policy.max_events_per_session == :infinity do
        {:ok, 0}
      else
        # Find sessions with too many events
        oversized =
          repo.all(
            from(e in EventSchema,
              group_by: e.session_id,
              having: count(e.id) > ^policy.max_events_per_session,
              select: {e.session_id, count(e.id)}
            )
          )

        total_pruned =
          Enum.reduce(oversized, 0, fn {session_id, _count}, acc ->
            acc + prune_count(repo, session_id, policy)
          end)

        {:ok, total_pruned}
      end
    rescue
      e -> {:error, Error.new(:maintenance_error, Exception.message(e))}
    end

    defp prune_count(repo, session_id, policy) do
      case do_prune_session_events(repo, session_id, policy) do
        {:ok, pruned} -> pruned
        _ -> 0
      end
    end

    defp do_prune_session_events(repo, session_id, %RetentionPolicy{} = policy) do
      max = policy.max_events_per_session
      if max == :infinity, do: {:ok, 0}, else: do_prune_events(repo, session_id, max, policy)
    rescue
      e -> {:error, Error.new(:maintenance_error, Exception.message(e))}
    end

    defp do_prune_events(repo, session_id, max_events, policy) do
      total_count =
        repo.one(from(e in EventSchema, where: e.session_id == ^session_id, select: count(e.id)))

      to_prune = total_count - max_events

      if to_prune <= 0 do
        {:ok, 0}
      else
        # First pass: prune low-value event types
        prune_types = Enum.map(policy.prune_event_types_first, &to_string/1)

        pruned_first =
          prune_by_types(repo, session_id, prune_types, to_prune)

        remaining = to_prune - pruned_first

        pruned_second =
          if remaining > 0 do
            prune_oldest(repo, session_id, remaining)
          else
            0
          end

        {:ok, pruned_first + pruned_second}
      end
    end

    defp prune_by_types(repo, session_id, types, limit) do
      ids =
        repo.all(
          from(e in EventSchema,
            where: e.session_id == ^session_id and e.type in ^types,
            order_by: [asc: e.sequence_number],
            limit: ^limit,
            select: e.id
          )
        )

      {count, _} = repo.delete_all(from(e in EventSchema, where: e.id in ^ids))
      count
    end

    defp prune_oldest(repo, session_id, limit) do
      # Never prune: session_created, run_started (first), run_completed (last), error_occurred, run_failed
      protected_types =
        Enum.map(
          [:session_created, :run_started, :run_completed, :error_occurred, :run_failed],
          &to_string/1
        )

      ids =
        repo.all(
          from(e in EventSchema,
            where: e.session_id == ^session_id and e.type not in ^protected_types,
            order_by: [asc: e.sequence_number],
            limit: ^limit,
            select: e.id
          )
        )

      {count, _} = repo.delete_all(from(e in EventSchema, where: e.id in ^ids))
      count
    end

    # ============================================================================
    # Clean orphaned artifacts
    # ============================================================================

    defp do_clean_orphaned_artifacts(repo) do
      orphan_ids =
        repo.all(
          from(a in ArtifactSchema,
            left_join: s in SessionSchema,
            on: a.session_id == s.id,
            where: is_nil(s.id) and not is_nil(a.session_id),
            select: a.id
          )
        )

      {count, _} = repo.delete_all(from(a in ArtifactSchema, where: a.id in ^orphan_ids))
      {:ok, count}
    rescue
      e -> {:error, Error.new(:maintenance_error, Exception.message(e))}
    end

    # ============================================================================
    # Clean orphaned sequences
    # ============================================================================

    defp do_clean_orphaned_sequences(repo) do
      orphan_ids =
        repo.all(
          from(sq in SessionSequenceSchema,
            left_join: s in SessionSchema,
            on: sq.session_id == s.id,
            where: is_nil(s.id),
            select: sq.session_id
          )
        )

      {count, _} =
        repo.delete_all(from(sq in SessionSequenceSchema, where: sq.session_id in ^orphan_ids))

      {:ok, count}
    rescue
      e -> {:error, Error.new(:maintenance_error, Exception.message(e))}
    end

    # ============================================================================
    # Health check
    # ============================================================================

    defp do_health_check(repo) do
      issues = []

      # Check: events reference existing sessions
      orphan_event_count =
        repo.one(
          from(e in EventSchema,
            left_join: s in SessionSchema,
            on: e.session_id == s.id,
            where: is_nil(s.id),
            select: count(e.id)
          )
        )

      issues =
        if orphan_event_count > 0,
          do: issues ++ ["#{orphan_event_count} events reference non-existent sessions"],
          else: issues

      # Check: runs reference existing sessions
      orphan_run_count =
        repo.one(
          from(r in RunSchema,
            left_join: s in SessionSchema,
            on: r.session_id == s.id,
            where: is_nil(s.id),
            select: count(r.id)
          )
        )

      issues =
        if orphan_run_count > 0,
          do: issues ++ ["#{orphan_run_count} runs reference non-existent sessions"],
          else: issues

      # Check: sequence counters match actual max sequence
      mismatches =
        repo.all(
          from(sq in SessionSequenceSchema,
            left_join: e in EventSchema,
            on: sq.session_id == e.session_id,
            group_by: [sq.session_id, sq.last_sequence],
            having: sq.last_sequence != max(e.sequence_number) and count(e.id) > 0,
            select: {sq.session_id, sq.last_sequence, max(e.sequence_number)}
          )
        )

      issues =
        Enum.reduce(mismatches, issues, fn {sid, expected, actual_max}, acc ->
          acc ++ ["Sequence mismatch for #{sid}: counter=#{expected}, max_sequence=#{actual_max}"]
        end)

      {:ok, issues}
    rescue
      e -> {:error, Error.new(:maintenance_error, Exception.message(e))}
    end

    # ============================================================================
    # Telemetry
    # ============================================================================

    defp emit_maintenance_telemetry(duration_ms) do
      :telemetry.execute(
        [:agent_session_manager, :maintenance, :complete],
        %{duration_ms: duration_ms},
        %{}
      )
    end
  end
else
  defmodule AgentSessionManager.Adapters.EctoMaintenance do
    @moduledoc """
    Fallback implementation used when optional Ecto dependencies are not installed.
    """

    @behaviour AgentSessionManager.Ports.Maintenance

    alias AgentSessionManager.OptionalDependency
    alias AgentSessionManager.Persistence.RetentionPolicy
    alias AgentSessionManager.Ports.Maintenance

    @impl Maintenance
    def execute(_repo, %RetentionPolicy{}), do: {:error, missing_dependency_error(:execute)}

    @impl Maintenance
    def prune_session_events(_repo, _session_id, %RetentionPolicy{}),
      do: {:error, missing_dependency_error(:prune_session_events)}

    @impl Maintenance
    def soft_delete_expired_sessions(_repo, %RetentionPolicy{}),
      do: {:error, missing_dependency_error(:soft_delete_expired_sessions)}

    @impl Maintenance
    def hard_delete_expired_sessions(_repo, %RetentionPolicy{}),
      do: {:error, missing_dependency_error(:hard_delete_expired_sessions)}

    @impl Maintenance
    def clean_orphaned_artifacts(_repo, _opts \\ []),
      do: {:error, missing_dependency_error(:clean_orphaned_artifacts)}

    @impl Maintenance
    def health_check(_repo), do: {:error, missing_dependency_error(:health_check)}

    defp missing_dependency_error(operation) do
      OptionalDependency.error(:ecto_sql, __MODULE__, operation)
    end
  end
end
