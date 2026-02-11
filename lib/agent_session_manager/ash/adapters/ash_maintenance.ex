if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Adapters.AshMaintenance do
    @moduledoc """
    Ash-based implementation of the `Maintenance` port.
    """

    @behaviour AgentSessionManager.Ports.Maintenance
    import Ash.Expr

    alias AgentSessionManager.Ash.Adapters.AshSessionStore
    alias AgentSessionManager.Ash.Converters
    alias AgentSessionManager.Ash.Resources
    alias AgentSessionManager.Core.Error
    alias AgentSessionManager.Persistence.RetentionPolicy

    @impl true
    def execute(domain, %RetentionPolicy{} = policy) do
      case RetentionPolicy.validate(policy) do
        :ok ->
          start = System.monotonic_time(:millisecond)
          errors = []

          {soft_deleted, errors} =
            safe_op(fn -> soft_delete_expired_sessions(domain, policy) end, errors)

          {hard_deleted, errors} =
            safe_op(fn -> hard_delete_expired_sessions(domain, policy) end, errors)

          {events_pruned, errors} = safe_op(fn -> prune_all_sessions(domain, policy) end, errors)

          {artifacts_cleaned, errors} =
            safe_op(fn -> clean_orphaned_artifacts(domain, []) end, errors)

          {orphaned_sequences_cleaned, errors} =
            safe_op(fn -> clean_orphaned_sequences(domain) end, errors)

          duration_ms = System.monotonic_time(:millisecond) - start
          emit_maintenance_telemetry(duration_ms)

          {:ok,
           %{
             sessions_soft_deleted: soft_deleted,
             sessions_hard_deleted: hard_deleted,
             events_pruned: events_pruned,
             artifacts_cleaned: artifacts_cleaned,
             orphaned_sequences_cleaned: orphaned_sequences_cleaned,
             duration_ms: duration_ms,
             errors: errors
           }}

        {:error, reason} ->
          {:error, Error.new(:validation_error, reason)}
      end
    end

    @impl true
    def prune_session_events(domain, session_id, %RetentionPolicy{} = policy) do
      if policy.max_events_per_session == :infinity do
        {:ok, 0}
      else
        events =
          Resources.Event
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(session_id == ^session_id)
          |> Ash.Query.sort(sequence_number: :asc)
          |> Ash.read!(domain: domain)
          |> Enum.map(&Converters.record_to_event/1)

        to_prune = length(events) - policy.max_events_per_session

        if to_prune <= 0 do
          {:ok, 0}
        else
          prune_types = Enum.map(policy.prune_event_types_first, &Atom.to_string/1)

          {first_pass, remaining_events} =
            events
            |> Enum.split_with(&(&1.type |> (Atom.to_string() in prune_types)))

          protected_types =
            MapSet.new(
              Enum.map(
                [:session_created, :run_started, :run_completed, :error_occurred, :run_failed],
                &Atom.to_string/1
              )
            )

          first = Enum.take(first_pass, to_prune)
          remaining_to_prune = to_prune - length(first)

          second =
            remaining_events
            |> Enum.reject(&MapSet.member?(protected_types, Atom.to_string(&1.type)))
            |> Enum.take(max(remaining_to_prune, 0))

          prune_ids = Enum.map(first ++ second, & &1.id)

          count =
            prune_ids
            |> Enum.reduce(0, fn id, acc ->
              case Ash.get(Resources.Event, id, domain: domain) do
                {:ok, nil} ->
                  acc

                {:ok, row} ->
                  case Ash.destroy(row, action: :destroy, domain: domain) do
                    :ok -> acc + 1
                    {:ok, _} -> acc + 1
                    _ -> acc
                  end

                _ ->
                  acc
              end
            end)

          {:ok, count}
        end
      end
    rescue
      e -> {:error, Error.new(:maintenance_error, Exception.message(e))}
    end

    @impl true
    def soft_delete_expired_sessions(domain, %RetentionPolicy{} = policy) do
      if policy.max_completed_session_age_days == :infinity do
        {:ok, 0}
      else
        cutoff = DateTime.add(DateTime.utc_now(), -policy.max_completed_session_age_days, :day)
        exempt_statuses = Enum.map(policy.exempt_statuses, &Atom.to_string/1)

        sessions =
          Resources.Session
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(is_nil(deleted_at) and updated_at < ^cutoff)
          |> Ash.read!(domain: domain)

        count =
          sessions
          |> Enum.reject(&(&1.status in exempt_statuses))
          |> Enum.reject(fn s -> Enum.any?(policy.exempt_tags, &(&1 in (s.tags || []))) end)
          |> Enum.reduce(0, fn s, acc ->
            case Ash.update(s, %{deleted_at: DateTime.utc_now()}, action: :update, domain: domain) do
              {:ok, _} -> acc + 1
              _ -> acc
            end
          end)

        {:ok, count}
      end
    rescue
      e -> {:error, Error.new(:maintenance_error, Exception.message(e))}
    end

    @impl true
    def hard_delete_expired_sessions(domain, %RetentionPolicy{} = policy) do
      if policy.hard_delete_after_days == :infinity do
        {:ok, 0}
      else
        cutoff = DateTime.add(DateTime.utc_now(), -policy.hard_delete_after_days, :day)

        sessions =
          Resources.Session
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(not is_nil(deleted_at) and deleted_at < ^cutoff)
          |> Ash.read!(domain: domain)

        store = {AshSessionStore, domain}

        count =
          Enum.reduce(sessions, 0, fn s, acc ->
            case AshSessionStore.delete_session(elem(store, 1), s.id) do
              :ok -> acc + 1
              _ -> acc
            end
          end)

        {:ok, count}
      end
    rescue
      e -> {:error, Error.new(:maintenance_error, Exception.message(e))}
    end

    @impl true
    def clean_orphaned_artifacts(domain, _opts \\ []) do
      session_ids =
        Resources.Session
        |> Ash.Query.for_read(:read)
        |> Ash.read!(domain: domain)
        |> MapSet.new(& &1.id)

      artifacts = Resources.Artifact |> Ash.Query.for_read(:read) |> Ash.read!(domain: domain)

      count =
        Enum.reduce(artifacts, 0, fn artifact, acc ->
          if artifact.session_id && not MapSet.member?(session_ids, artifact.session_id) do
            case Ash.destroy(artifact, action: :destroy, domain: domain) do
              :ok -> acc + 1
              {:ok, _} -> acc + 1
              _ -> acc
            end
          else
            acc
          end
        end)

      {:ok, count}
    rescue
      e -> {:error, Error.new(:maintenance_error, Exception.message(e))}
    end

    @impl true
    def health_check(domain) do
      sessions = Resources.Session |> Ash.Query.for_read(:read) |> Ash.read!(domain: domain)
      runs = Resources.Run |> Ash.Query.for_read(:read) |> Ash.read!(domain: domain)
      events = Resources.Event |> Ash.Query.for_read(:read) |> Ash.read!(domain: domain)

      sequences =
        Resources.SessionSequence |> Ash.Query.for_read(:read) |> Ash.read!(domain: domain)

      session_ids = MapSet.new(sessions, & &1.id)

      orphan_events =
        Enum.count(events, fn e -> not MapSet.member?(session_ids, e.session_id) end)

      orphan_runs = Enum.count(runs, fn r -> not MapSet.member?(session_ids, r.session_id) end)

      sequence_issues =
        sequences
        |> Enum.flat_map(fn seq ->
          max_seq =
            events
            |> Enum.filter(&(&1.session_id == seq.session_id))
            |> Enum.map(&(&1.sequence_number || 0))
            |> Enum.max(fn -> 0 end)

          if max_seq > 0 and max_seq != seq.last_sequence do
            [
              "Sequence mismatch for #{seq.session_id}: counter=#{seq.last_sequence}, max_sequence=#{max_seq}"
            ]
          else
            []
          end
        end)

      issues = []

      issues =
        if orphan_events > 0,
          do: issues ++ ["#{orphan_events} events reference non-existent sessions"],
          else: issues

      issues =
        if orphan_runs > 0,
          do: issues ++ ["#{orphan_runs} runs reference non-existent sessions"],
          else: issues

      {:ok, issues ++ sequence_issues}
    rescue
      e -> {:error, Error.new(:maintenance_error, Exception.message(e))}
    end

    defp prune_all_sessions(domain, %RetentionPolicy{} = policy) do
      session_ids =
        Resources.Event
        |> Ash.Query.for_read(:read)
        |> Ash.read!(domain: domain)
        |> Enum.group_by(& &1.session_id)
        |> Enum.filter(fn {_session_id, events} ->
          length(events) > policy.max_events_per_session
        end)
        |> Enum.map(&elem(&1, 0))

      total =
        Enum.reduce(session_ids, 0, fn session_id, acc ->
          case prune_session_events(domain, session_id, policy) do
            {:ok, pruned} -> acc + pruned
            _ -> acc
          end
        end)

      {:ok, total}
    end

    defp clean_orphaned_sequences(domain) do
      session_ids =
        Resources.Session
        |> Ash.Query.for_read(:read)
        |> Ash.read!(domain: domain)
        |> MapSet.new(& &1.id)

      sequences =
        Resources.SessionSequence |> Ash.Query.for_read(:read) |> Ash.read!(domain: domain)

      count =
        Enum.reduce(sequences, 0, fn seq, acc ->
          if MapSet.member?(session_ids, seq.session_id) do
            acc
          else
            case Ash.destroy(seq, action: :destroy, domain: domain) do
              :ok -> acc + 1
              {:ok, _} -> acc + 1
              _ -> acc
            end
          end
        end)

      {:ok, count}
    end

    defp safe_op(func, errors) do
      case func.() do
        {:ok, count} -> {count, errors}
        {:error, %Error{message: msg}} -> {0, errors ++ [msg]}
        {:error, msg} -> {0, errors ++ [inspect(msg)]}
      end
    end

    defp emit_maintenance_telemetry(duration_ms) do
      :telemetry.execute(
        [:agent_session_manager, :maintenance, :complete],
        %{duration_ms: duration_ms},
        %{}
      )
    end
  end
else
  defmodule AgentSessionManager.Ash.Adapters.AshMaintenance do
    @moduledoc """
    Fallback implementation used when optional Ash dependencies are not installed.
    """

    @behaviour AgentSessionManager.Ports.Maintenance
    alias AgentSessionManager.OptionalDependency
    alias AgentSessionManager.Persistence.RetentionPolicy
    alias AgentSessionManager.Ports.Maintenance

    @impl Maintenance
    def execute(_domain, %RetentionPolicy{}), do: {:error, missing_dep_error(:execute)}

    @impl Maintenance
    def prune_session_events(_domain, _session_id, %RetentionPolicy{}),
      do: {:error, missing_dep_error(:prune_session_events)}

    @impl Maintenance
    def soft_delete_expired_sessions(_domain, %RetentionPolicy{}),
      do: {:error, missing_dep_error(:soft_delete_expired_sessions)}

    @impl Maintenance
    def hard_delete_expired_sessions(_domain, %RetentionPolicy{}),
      do: {:error, missing_dep_error(:hard_delete_expired_sessions)}

    @impl Maintenance
    def clean_orphaned_artifacts(_domain, _opts \\ []),
      do: {:error, missing_dep_error(:clean_orphaned_artifacts)}

    @impl Maintenance
    def health_check(_domain), do: {:error, missing_dep_error(:health_check)}

    defp missing_dep_error(op), do: OptionalDependency.error(:ash, __MODULE__, op)
  end
end
