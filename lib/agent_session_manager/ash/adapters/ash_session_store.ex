if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Adapters.AshSessionStore do
    @moduledoc """
    Ash-based implementation of the `SessionStore` port.

    Uses Ash resources backed by AshPostgres for persistence.
    """

    @behaviour AgentSessionManager.Ports.SessionStore

    import Ash.Expr
    require Ash.Query

    alias AgentSessionManager.Ash.Changes.AssignSequence
    alias AgentSessionManager.Ash.Converters
    alias AgentSessionManager.Ash.Resources
    alias AgentSessionManager.Core.{Error, Event, Run, Session}
    alias AshPostgres.DataLayer.Info, as: DataLayerInfo

    @impl true
    def save_session(domain, %Session{} = session) do
      session
      |> Converters.session_to_attrs()
      |> then(&Ash.create(Resources.Session, &1, action: :upsert, domain: domain))
      |> normalize_ok()
    rescue
      e -> {:error, storage_error("save_session failed", e)}
    end

    @impl true
    def get_session(domain, session_id) do
      case Ash.get(Resources.Session, session_id, domain: domain) do
        {:ok, nil} ->
          {:error, Error.new(:session_not_found, "Session not found: #{session_id}")}

        {:ok, record} ->
          {:ok, Converters.record_to_session(record)}

        {:error, error} ->
          {:error, storage_error("get_session failed", error)}
      end
    rescue
      e -> {:error, storage_error("get_session failed", e)}
    end

    @impl true
    def list_sessions(domain, opts \\ []) do
      query =
        Resources.Session
        |> Ash.Query.for_read(:read)
        |> maybe_filter_session_status(opts)
        |> maybe_filter_agent_id(opts)
        |> maybe_limit(opts)

      case Ash.read(query, domain: domain) do
        {:ok, sessions} -> {:ok, Enum.map(sessions, &Converters.record_to_session/1)}
        {:error, error} -> {:error, storage_error("list_sessions failed", error)}
      end
    rescue
      e -> {:error, storage_error("list_sessions failed", e)}
    end

    @impl true
    def delete_session(_domain, session_id) do
      repo = DataLayerInfo.repo(Resources.Session, :mutate)

      case repo.transaction(fn ->
             repo.query!("DELETE FROM asm_events WHERE session_id = $1", [session_id])
             repo.query!("DELETE FROM asm_runs WHERE session_id = $1", [session_id])
             repo.query!("DELETE FROM asm_artifacts WHERE session_id = $1", [session_id])
             repo.query!("DELETE FROM asm_session_sequences WHERE session_id = $1", [session_id])
             repo.query!("DELETE FROM asm_sessions WHERE id = $1", [session_id])
           end) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, storage_error("delete_session failed", reason)}
      end
    rescue
      e -> {:error, storage_error("delete_session failed", e)}
    end

    @impl true
    def save_run(domain, %Run{} = run) do
      run
      |> Converters.run_to_attrs()
      |> then(&Ash.create(Resources.Run, &1, action: :upsert, domain: domain))
      |> normalize_ok()
    rescue
      e -> {:error, storage_error("save_run failed", e)}
    end

    @impl true
    def get_run(domain, run_id) do
      case Ash.get(Resources.Run, run_id, domain: domain) do
        {:ok, nil} ->
          {:error, Error.new(:run_not_found, "Run not found: #{run_id}")}

        {:ok, record} ->
          {:ok, Converters.record_to_run(record)}

        {:error, error} ->
          {:error, storage_error("get_run failed", error)}
      end
    rescue
      e -> {:error, storage_error("get_run failed", e)}
    end

    @impl true
    def list_runs(domain, session_id, opts \\ []) do
      query =
        Resources.Run
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(expr(session_id == ^session_id))
        |> maybe_filter_run_status(opts)
        |> maybe_limit(opts)

      case Ash.read(query, domain: domain) do
        {:ok, runs} -> {:ok, Enum.map(runs, &Converters.record_to_run/1)}
        {:error, error} -> {:error, storage_error("list_runs failed", error)}
      end
    rescue
      e -> {:error, storage_error("list_runs failed", e)}
    end

    @impl true
    def get_active_run(domain, session_id) do
      query =
        Resources.Run
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(expr(session_id == ^session_id and status == "running"))
        |> Ash.Query.limit(1)

      case Ash.read(query, domain: domain) do
        {:ok, []} -> {:ok, nil}
        {:ok, [run | _]} -> {:ok, Converters.record_to_run(run)}
        {:error, error} -> {:error, storage_error("get_active_run failed", error)}
      end
    rescue
      e -> {:error, storage_error("get_active_run failed", e)}
    end

    @impl true
    def append_event(domain, %Event{} = event) do
      case append_event_with_sequence(domain, event) do
        {:ok, _event} -> :ok
        {:error, _} = error -> error
      end
    end

    @impl true
    def append_event_with_sequence(domain, %Event{} = event) do
      with {:ok, existing} <- fetch_event(domain, event.id) do
        maybe_create_event_with_sequence(domain, event, existing)
      end
    rescue
      e -> {:error, storage_error("append_event_with_sequence failed", e)}
    end

    @impl true
    def append_events(domain, events) when is_list(events) do
      with :ok <- validate_events(events),
           {:ok, persisted_by_id} <- persist_events_batch(domain, events) do
        {:ok, Enum.map(events, &Map.fetch!(persisted_by_id, &1.id))}
      end
    rescue
      e -> {:error, storage_error("append_events failed", e)}
    end

    def append_events(_domain, _events) do
      {:error, Error.new(:validation_error, "events must be a list")}
    end

    @impl true
    def flush(domain, %{session: %Session{} = session, run: %Run{} = run, events: events})
        when is_list(events) do
      repo = DataLayerInfo.repo(Resources.Session, :mutate)

      case repo.transaction(fn -> flush_in_transaction(domain, repo, session, run, events) end) do
        {:ok, :ok} -> :ok
        {:error, %Error{} = error} -> {:error, error}
        {:error, reason} -> {:error, storage_error("flush failed", reason)}
      end
    rescue
      e -> {:error, storage_error("flush failed", e)}
    end

    def flush(_domain, _execution_result) do
      {:error, Error.new(:validation_error, "invalid execution_result payload")}
    end

    @impl true
    def get_events(domain, session_id, opts \\ []) do
      query =
        Resources.Event
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(expr(session_id == ^session_id))
        |> Ash.Query.sort(sequence_number: :asc)
        |> maybe_filter_event_run_id(opts)
        |> maybe_filter_event_type(opts)
        |> maybe_filter_since(opts)
        |> maybe_filter_after(opts)
        |> maybe_filter_before(opts)
        |> maybe_limit(opts)

      case Ash.read(query, domain: domain) do
        {:ok, events} -> {:ok, Enum.map(events, &Converters.record_to_event/1)}
        {:error, error} -> {:error, storage_error("get_events failed", error)}
      end
    rescue
      e -> {:error, storage_error("get_events failed", e)}
    end

    @impl true
    def get_latest_sequence(domain, session_id) do
      case Ash.get(Resources.SessionSequence, session_id, domain: domain) do
        {:ok, nil} -> {:ok, 0}
        {:ok, seq} -> {:ok, seq.last_sequence}
        {:error, error} -> {:error, storage_error("get_latest_sequence failed", error)}
      end
    rescue
      e -> {:error, storage_error("get_latest_sequence failed", e)}
    end

    defp flush_in_transaction(domain, repo, session, run, events) do
      with :ok <- save_session(domain, session),
           :ok <- save_run(domain, run),
           {:ok, _} <- append_events(domain, events) do
        :ok
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end

    defp fetch_event(domain, event_id) do
      case Ash.get(Resources.Event, event_id, domain: domain) do
        {:ok, nil} -> {:ok, nil}
        {:ok, event} -> {:ok, Converters.record_to_event(event)}
        {:error, error} -> {:error, storage_error("fetch event failed", error)}
      end
    end

    defp maybe_create_event_with_sequence(_domain, _event, %Event{} = existing),
      do: {:ok, existing}

    defp maybe_create_event_with_sequence(domain, event, nil) do
      repo = DataLayerInfo.repo(Resources.Event, :mutate)
      seq = AssignSequence.next_sequence(repo, event.session_id)
      attrs = Converters.event_to_attrs_with_sequence(event, seq)

      case Ash.create(Resources.Event, attrs, action: :create, domain: domain) do
        {:ok, stored} -> {:ok, Converters.record_to_event(stored)}
        {:error, error} -> {:error, storage_error("insert event failed", error)}
      end
    end

    defp validate_events(events) do
      if Enum.all?(events, &match?(%Event{}, &1)) do
        :ok
      else
        {:error, Error.new(:validation_error, "events must be Event structs")}
      end
    end

    defp persist_events_batch(domain, events) do
      unique_events = unique_events_by_id(events)
      unique_ids = Enum.map(unique_events, & &1.id)

      existing_by_id =
        Resources.Event
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(expr(id in ^unique_ids))
        |> then(&Ash.read(&1, domain: domain))
        |> case do
          {:ok, rows} ->
            rows
            |> Enum.map(&Converters.record_to_event/1)
            |> Map.new(&{&1.id, &1})

          {:error, error} ->
            throw({:error, storage_error("load existing events failed", error)})
        end

      new_events = Enum.reject(unique_events, &Map.has_key?(existing_by_id, &1.id))

      case insert_new_events(domain, new_events) do
        {:ok, inserted_by_id} -> {:ok, Map.merge(existing_by_id, inserted_by_id)}
        {:error, _} = error -> error
      end
    catch
      {:error, _} = error -> error
    end

    defp insert_new_events(_domain, []), do: {:ok, %{}}

    defp insert_new_events(domain, events) do
      repo = DataLayerInfo.repo(Resources.Event, :mutate)
      grouped = Enum.group_by(events, & &1.session_id)

      Enum.reduce_while(grouped, {:ok, %{}}, fn {session_id, session_events}, {:ok, acc} ->
        first_seq = AssignSequence.reserve_batch(repo, session_id, length(session_events))

        case insert_session_events(domain, session_events, first_seq) do
          {:ok, inserted_map} -> {:cont, {:ok, Map.merge(acc, inserted_map)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end

    defp insert_session_events(domain, session_events, first_seq) do
      session_events
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, %{}}, fn {event, idx}, {:ok, event_acc} ->
        seq = first_seq + idx
        attrs = Converters.event_to_attrs_with_sequence(event, seq)

        case Ash.create(Resources.Event, attrs, action: :create, domain: domain) do
          {:ok, record} ->
            stored = Converters.record_to_event(record)
            {:cont, {:ok, Map.put(event_acc, stored.id, stored)}}

          {:error, error} ->
            {:halt, {:error, storage_error("insert event batch failed", error)}}
        end
      end)
    end

    defp unique_events_by_id(events) do
      {_, unique_reversed} =
        Enum.reduce(events, {MapSet.new(), []}, fn event, {seen_ids, acc} ->
          if MapSet.member?(seen_ids, event.id) do
            {seen_ids, acc}
          else
            {MapSet.put(seen_ids, event.id), [event | acc]}
          end
        end)

      Enum.reverse(unique_reversed)
    end

    defp maybe_filter_session_status(query, opts) do
      case Keyword.get(opts, :status) do
        nil -> query
        status -> Ash.Query.filter(query, expr(status == ^Atom.to_string(status)))
      end
    end

    defp maybe_filter_agent_id(query, opts) do
      case Keyword.get(opts, :agent_id) do
        nil -> query
        agent_id -> Ash.Query.filter(query, expr(agent_id == ^agent_id))
      end
    end

    defp maybe_filter_run_status(query, opts) do
      case Keyword.get(opts, :status) do
        nil -> query
        status -> Ash.Query.filter(query, expr(status == ^Atom.to_string(status)))
      end
    end

    defp maybe_filter_event_run_id(query, opts) do
      case Keyword.get(opts, :run_id) do
        nil -> query
        run_id -> Ash.Query.filter(query, expr(run_id == ^run_id))
      end
    end

    defp maybe_filter_event_type(query, opts) do
      case Keyword.get(opts, :type) do
        nil -> query
        type -> Ash.Query.filter(query, expr(type == ^Atom.to_string(type)))
      end
    end

    defp maybe_filter_since(query, opts) do
      case Keyword.get(opts, :since) do
        nil -> query
        since -> Ash.Query.filter(query, expr(timestamp > ^since))
      end
    end

    defp maybe_filter_after(query, opts) do
      case Keyword.get(opts, :after) do
        nil -> query
        seq -> Ash.Query.filter(query, expr(sequence_number > ^seq))
      end
    end

    defp maybe_filter_before(query, opts) do
      case Keyword.get(opts, :before) do
        nil -> query
        seq -> Ash.Query.filter(query, expr(sequence_number < ^seq))
      end
    end

    defp maybe_limit(query, opts) do
      case Keyword.get(opts, :limit) do
        nil -> query
        n when is_integer(n) and n > 0 -> Ash.Query.limit(query, n)
        _ -> query
      end
    end

    defp normalize_ok({:ok, _}), do: :ok
    defp normalize_ok({:error, error}), do: {:error, storage_error("storage op failed", error)}

    defp storage_error(prefix, reason) do
      Error.new(:storage_error, "#{prefix}: #{inspect(reason)}")
    end
  end
else
  defmodule AgentSessionManager.Ash.Adapters.AshSessionStore do
    @moduledoc """
    Fallback implementation used when optional Ash dependencies are not installed.
    """

    @behaviour AgentSessionManager.Ports.SessionStore

    alias AgentSessionManager.OptionalDependency
    alias AgentSessionManager.Ports.SessionStore

    @impl SessionStore
    def save_session(_domain, _session), do: {:error, missing_dep_error(:save_session)}

    @impl SessionStore
    def get_session(_domain, _session_id), do: {:error, missing_dep_error(:get_session)}

    @impl SessionStore
    def list_sessions(_domain, _opts \\ []), do: {:error, missing_dep_error(:list_sessions)}

    @impl SessionStore
    def delete_session(_domain, _session_id), do: {:error, missing_dep_error(:delete_session)}

    @impl SessionStore
    def save_run(_domain, _run), do: {:error, missing_dep_error(:save_run)}

    @impl SessionStore
    def get_run(_domain, _run_id), do: {:error, missing_dep_error(:get_run)}

    @impl SessionStore
    def list_runs(_domain, _session_id, _opts \\ []), do: {:error, missing_dep_error(:list_runs)}

    @impl SessionStore
    def get_active_run(_domain, _session_id), do: {:error, missing_dep_error(:get_active_run)}

    @impl SessionStore
    def append_event(_domain, _event), do: {:error, missing_dep_error(:append_event)}

    @impl SessionStore
    def append_event_with_sequence(_domain, _event),
      do: {:error, missing_dep_error(:append_event_with_sequence)}

    @impl SessionStore
    def append_events(_domain, _events), do: {:error, missing_dep_error(:append_events)}

    @impl SessionStore
    def flush(_domain, _execution_result), do: {:error, missing_dep_error(:flush)}

    @impl SessionStore
    def get_events(_domain, _session_id, _opts \\ []),
      do: {:error, missing_dep_error(:get_events)}

    @impl SessionStore
    def get_latest_sequence(_domain, _session_id),
      do: {:error, missing_dep_error(:get_latest_sequence)}

    defp missing_dep_error(op), do: OptionalDependency.error(:ash, __MODULE__, op)
  end
end
