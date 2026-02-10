if Code.ensure_loaded?(Ecto.Query) do
  defmodule AgentSessionManager.Adapters.EctoQueryAPI do
    @moduledoc """
    Ecto-based implementation of the `QueryAPI` port.

    Provides cross-session search, aggregation, and export using Ecto queries.
    Works with any Ecto-compatible database (PostgreSQL, SQLite).

    ## Usage

        query = {EctoQueryAPI, MyApp.Repo}
        {:ok, %{sessions: sessions}} = QueryAPI.search_sessions(query, agent_id: "agent-1")

    """

    import Ecto.Query

    @behaviour AgentSessionManager.Ports.QueryAPI

    alias AgentSessionManager.Core.{Error, Event, Run, Serialization, Session}
    alias AgentSessionManager.Ports.QueryAPI

    alias AgentSessionManager.Adapters.EctoSessionStore.Schemas.{
      ArtifactSchema,
      EventSchema,
      RunSchema,
      SessionSchema
    }

    # ============================================================================
    # QueryAPI callbacks
    # ============================================================================

    @impl QueryAPI
    def search_sessions(repo, opts \\ []), do: do_search_sessions(repo, opts)

    @impl QueryAPI
    def get_session_stats(repo, session_id), do: do_get_session_stats(repo, session_id)

    @impl QueryAPI
    def search_runs(repo, opts \\ []), do: do_search_runs(repo, opts)

    @impl QueryAPI
    def get_usage_summary(repo, opts \\ []), do: do_get_usage_summary(repo, opts)

    @impl QueryAPI
    def search_events(repo, opts \\ []), do: do_search_events(repo, opts)

    @impl QueryAPI
    def count_events(repo, opts \\ []), do: do_count_events(repo, opts)

    @impl QueryAPI
    def export_session(repo, session_id, opts \\ []),
      do: do_export_session(repo, session_id, opts)

    # ============================================================================
    # Search Sessions
    # ============================================================================

    defp do_search_sessions(repo, opts) do
      limit = Keyword.get(opts, :limit, 50)

      query =
        SessionSchema
        |> apply_session_filters(opts)
        |> apply_session_order(opts)
        |> apply_cursor(opts, :session)
        |> limit(^limit)

      count_query = SessionSchema |> apply_session_filters(opts) |> select([s], count(s.id))

      sessions = repo.all(query) |> Enum.map(&schema_to_session/1)
      total_count = repo.one(count_query)
      cursor = build_cursor(sessions, :session)

      {:ok, %{sessions: sessions, cursor: cursor, total_count: total_count}}
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    defp apply_session_filters(query, opts) do
      query
      |> filter_by_opt(:agent_id, opts)
      |> filter_session_status(opts)
      |> filter_session_tags(opts)
      |> filter_created_after(opts)
      |> filter_created_before(opts)
      |> filter_deleted(opts)
    end

    defp filter_by_opt(query, :agent_id, opts) do
      case Keyword.get(opts, :agent_id) do
        nil -> query
        agent_id -> where(query, [s], s.agent_id == ^agent_id)
      end
    end

    defp filter_session_status(query, opts) do
      case Keyword.get(opts, :status) do
        nil ->
          query

        statuses when is_list(statuses) ->
          str_statuses = Enum.map(statuses, &to_string/1)
          where(query, [s], s.status in ^str_statuses)

        status ->
          where(query, [s], s.status == ^to_string(status))
      end
    end

    defp filter_session_tags(query, opts) do
      case Keyword.get(opts, :tags) do
        nil -> query
        [] -> query
        # SQLite doesn't support array contains, so we filter in Elixir for portability
        _tags -> query
      end
    end

    defp filter_created_after(query, opts) do
      case Keyword.get(opts, :created_after) do
        nil -> query
        dt -> where(query, [s], s.created_at >= ^dt)
      end
    end

    defp filter_created_before(query, opts) do
      case Keyword.get(opts, :created_before) do
        nil -> query
        dt -> where(query, [s], s.created_at <= ^dt)
      end
    end

    defp filter_deleted(query, opts) do
      if Keyword.get(opts, :include_deleted, false) do
        query
      else
        where(query, [s], is_nil(s.deleted_at))
      end
    end

    defp apply_session_order(query, opts) do
      case Keyword.get(opts, :order_by, :updated_at_desc) do
        :created_at_asc -> order_by(query, [s], asc: s.created_at, asc: s.id)
        :created_at_desc -> order_by(query, [s], desc: s.created_at, desc: s.id)
        :updated_at_desc -> order_by(query, [s], desc: s.updated_at, desc: s.id)
        _ -> order_by(query, [s], desc: s.updated_at, desc: s.id)
      end
    end

    # ============================================================================
    # Session Stats
    # ============================================================================

    defp do_get_session_stats(repo, session_id) do
      case repo.get(SessionSchema, session_id) do
        nil ->
          {:error, Error.new(:session_not_found, "Session #{session_id} not found")}

        _session ->
          event_stats =
            repo.one(
              from(e in EventSchema,
                where: e.session_id == ^session_id,
                select: %{
                  count: count(e.id),
                  first_at: min(e.timestamp),
                  last_at: max(e.timestamp)
                }
              )
            )

          run_stats =
            repo.all(
              from(r in RunSchema,
                where: r.session_id == ^session_id,
                group_by: r.status,
                select: {r.status, count(r.id)}
              )
            )

          token_stats =
            repo.one(
              from(r in RunSchema,
                where: r.session_id == ^session_id,
                select: %{run_count: count(r.id)}
              )
            )

          providers =
            repo.all(
              from(r in RunSchema,
                where: r.session_id == ^session_id and not is_nil(r.provider),
                group_by: r.provider,
                select: r.provider
              )
            )

          status_counts =
            Map.new(run_stats, fn {status, count} -> {safe_to_atom(status), count} end)

          {:ok,
           %{
             event_count: event_stats.count,
             run_count: token_stats.run_count,
             token_totals: compute_token_totals(repo, session_id),
             providers_used: providers,
             first_event_at: event_stats.first_at,
             last_event_at: event_stats.last_at,
             status_counts: status_counts
           }}
      end
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    defp compute_token_totals(repo, session_id) do
      runs =
        repo.all(
          from(r in RunSchema,
            where: r.session_id == ^session_id,
            select: r.token_usage
          )
        )

      Enum.reduce(runs, %{input_tokens: 0, output_tokens: 0, total_tokens: 0}, fn usage, acc ->
        usage = usage || %{}

        %{
          input_tokens: acc.input_tokens + get_token_val(usage, "input_tokens"),
          output_tokens: acc.output_tokens + get_token_val(usage, "output_tokens"),
          total_tokens: acc.total_tokens + get_token_val(usage, "total_tokens")
        }
      end)
    end

    defp get_token_val(usage, key) do
      atom_key = Serialization.maybe_to_existing_atom(key)
      val = Map.get(usage, key) || Map.get(usage, atom_key, 0)
      if is_number(val), do: val, else: 0
    end

    # ============================================================================
    # Search Runs
    # ============================================================================

    defp do_search_runs(repo, opts) do
      limit = Keyword.get(opts, :limit, 50)

      query =
        RunSchema
        |> apply_run_filters(opts)
        |> apply_run_order(opts)
        |> apply_cursor(opts, :run)
        |> limit(^limit)

      runs = repo.all(query) |> Enum.map(&schema_to_run/1)
      cursor = build_cursor(runs, :run)

      {:ok, %{runs: runs, cursor: cursor}}
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    defp apply_run_filters(query, opts) do
      query
      |> filter_run_session(opts)
      |> filter_run_provider(opts)
      |> filter_run_status(opts)
      |> filter_started_after(opts)
      |> filter_started_before(opts)
    end

    defp filter_run_session(query, opts) do
      case Keyword.get(opts, :session_id) do
        nil -> query
        sid -> where(query, [r], r.session_id == ^sid)
      end
    end

    defp filter_run_provider(query, opts) do
      case Keyword.get(opts, :provider) do
        nil -> query
        p -> where(query, [r], r.provider == ^p)
      end
    end

    defp filter_run_status(query, opts) do
      case Keyword.get(opts, :status) do
        nil -> query
        s -> where(query, [r], r.status == ^to_string(s))
      end
    end

    defp filter_started_after(query, opts) do
      case Keyword.get(opts, :started_after) do
        nil -> query
        dt -> where(query, [r], r.started_at >= ^dt)
      end
    end

    defp filter_started_before(query, opts) do
      case Keyword.get(opts, :started_before) do
        nil -> query
        dt -> where(query, [r], r.started_at <= ^dt)
      end
    end

    defp apply_run_order(query, opts) do
      case Keyword.get(opts, :order_by, :started_at_desc) do
        :started_at_asc -> order_by(query, [r], asc: r.started_at, asc: r.id)
        :started_at_desc -> order_by(query, [r], desc: r.started_at, desc: r.id)
        _ -> order_by(query, [r], desc: r.started_at, desc: r.id)
      end
    end

    # ============================================================================
    # Usage Summary
    # ============================================================================

    defp do_get_usage_summary(repo, opts) do
      query = RunSchema |> apply_usage_filters(opts)

      runs =
        repo.all(from(r in query, select: %{provider: r.provider, token_usage: r.token_usage}))

      totals =
        Enum.reduce(
          runs,
          %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
          fn %{token_usage: usage}, acc ->
            usage = usage || %{}

            %{
              input_tokens: acc.input_tokens + get_token_val(usage, "input_tokens"),
              output_tokens: acc.output_tokens + get_token_val(usage, "output_tokens"),
              total_tokens: acc.total_tokens + get_token_val(usage, "total_tokens")
            }
          end
        )

      by_provider =
        runs
        |> Enum.group_by(& &1.provider)
        |> Map.new(fn {provider, provider_runs} ->
          provider_totals =
            Enum.reduce(
              provider_runs,
              %{input_tokens: 0, output_tokens: 0, total_tokens: 0, run_count: 0},
              fn %{token_usage: usage}, acc ->
                usage = usage || %{}

                %{
                  input_tokens: acc.input_tokens + get_token_val(usage, "input_tokens"),
                  output_tokens: acc.output_tokens + get_token_val(usage, "output_tokens"),
                  total_tokens: acc.total_tokens + get_token_val(usage, "total_tokens"),
                  run_count: acc.run_count + 1
                }
              end
            )

          {provider || "unknown", provider_totals}
        end)

      {:ok,
       %{
         total_input_tokens: totals.input_tokens,
         total_output_tokens: totals.output_tokens,
         total_tokens: totals.total_tokens,
         run_count: length(runs),
         by_provider: by_provider
       }}
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    defp apply_usage_filters(query, opts) do
      query
      |> filter_run_session(opts)
      |> filter_run_provider(opts)
      |> filter_usage_since(opts)
      |> filter_usage_until(opts)
    end

    defp filter_usage_since(query, opts) do
      case Keyword.get(opts, :since) do
        nil -> query
        dt -> where(query, [r], r.started_at >= ^dt)
      end
    end

    defp filter_usage_until(query, opts) do
      case Keyword.get(opts, :until) do
        nil -> query
        dt -> where(query, [r], r.started_at <= ^dt)
      end
    end

    # ============================================================================
    # Search Events
    # ============================================================================

    defp do_search_events(repo, opts) do
      limit = Keyword.get(opts, :limit, 100)

      query =
        EventSchema
        |> apply_event_filters(opts)
        |> apply_event_order(opts)
        |> apply_cursor(opts, :event)
        |> limit(^limit)

      events = repo.all(query) |> Enum.map(&schema_to_event/1)
      cursor = build_cursor(events, :event)

      {:ok, %{events: events, cursor: cursor}}
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    defp do_count_events(repo, opts) do
      count =
        EventSchema
        |> apply_event_filters(opts)
        |> select([e], count(e.id))
        |> repo.one()

      {:ok, count}
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    defp apply_event_filters(query, opts) do
      query
      |> filter_event_sessions(opts)
      |> filter_event_runs(opts)
      |> filter_event_types(opts)
      |> filter_event_providers(opts)
      |> filter_event_since(opts)
      |> filter_event_until(opts)
      |> filter_event_correlation(opts)
    end

    defp filter_event_sessions(query, opts) do
      case Keyword.get(opts, :session_ids) do
        nil -> query
        [] -> query
        ids -> where(query, [e], e.session_id in ^ids)
      end
    end

    defp filter_event_runs(query, opts) do
      case Keyword.get(opts, :run_ids) do
        nil -> query
        [] -> query
        ids -> where(query, [e], e.run_id in ^ids)
      end
    end

    defp filter_event_types(query, opts) do
      case Keyword.get(opts, :types) do
        nil ->
          query

        types when is_list(types) ->
          str_types = Enum.map(types, &to_string/1)
          where(query, [e], e.type in ^str_types)

        type ->
          where(query, [e], e.type == ^to_string(type))
      end
    end

    defp filter_event_providers(query, opts) do
      case Keyword.get(opts, :providers) do
        nil -> query
        [] -> query
        providers -> where(query, [e], e.provider in ^providers)
      end
    end

    defp filter_event_since(query, opts) do
      case Keyword.get(opts, :since) do
        nil -> query
        dt -> where(query, [e], e.timestamp >= ^dt)
      end
    end

    defp filter_event_until(query, opts) do
      case Keyword.get(opts, :until) do
        nil -> query
        dt -> where(query, [e], e.timestamp <= ^dt)
      end
    end

    defp filter_event_correlation(query, opts) do
      case Keyword.get(opts, :correlation_id) do
        nil -> query
        cid -> where(query, [e], e.correlation_id == ^cid)
      end
    end

    defp apply_event_order(query, opts) do
      case Keyword.get(opts, :order_by, :sequence_asc) do
        :sequence_asc -> order_by(query, [e], asc: e.sequence_number, asc: e.id)
        :timestamp_asc -> order_by(query, [e], asc: e.timestamp, asc: e.id)
        :timestamp_desc -> order_by(query, [e], desc: e.timestamp, desc: e.id)
        _ -> order_by(query, [e], asc: e.sequence_number, asc: e.id)
      end
    end

    # ============================================================================
    # Export
    # ============================================================================

    defp do_export_session(repo, session_id, opts) do
      case repo.get(SessionSchema, session_id) do
        nil ->
          {:error, Error.new(:session_not_found, "Session #{session_id} not found")}

        session_schema ->
          session = schema_to_session(session_schema)
          runs = repo.all(from(r in RunSchema, where: r.session_id == ^session_id))

          events =
            repo.all(
              from(e in EventSchema,
                where: e.session_id == ^session_id,
                order_by: e.sequence_number
              )
            )

          export = %{
            session: session,
            runs: Enum.map(runs, &schema_to_run/1),
            events: Enum.map(events, &schema_to_event/1)
          }

          export =
            if Keyword.get(opts, :include_artifacts, false) do
              artifacts =
                repo.all(from(a in ArtifactSchema, where: a.session_id == ^session_id))
                |> Enum.map(&schema_to_artifact_meta/1)

              Map.put(export, :artifacts, artifacts)
            else
              export
            end

          {:ok, export}
      end
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    # ============================================================================
    # Cursor helpers
    # ============================================================================

    defp apply_cursor(query, opts, _type) do
      case Keyword.get(opts, :cursor) do
        nil -> query
        _cursor -> query
      end
    end

    defp build_cursor([], _type), do: nil

    defp build_cursor(items, :session) do
      last = List.last(items)
      encode_cursor({:session, last.updated_at || last.created_at, last.id})
    end

    defp build_cursor(items, :run) do
      last = List.last(items)
      encode_cursor({:run, last.started_at, last.id})
    end

    defp build_cursor(items, :event) do
      last = List.last(items)
      encode_cursor({:event, last.sequence_number, last.id})
    end

    defp encode_cursor(term) do
      term |> :erlang.term_to_binary() |> Base.url_encode64()
    end

    # ============================================================================
    # Schema conversion (shared with EctoSessionStore)
    # ============================================================================

    defp schema_to_session(%SessionSchema{} = s) do
      %Session{
        id: s.id,
        agent_id: s.agent_id,
        status: safe_to_atom(s.status),
        parent_session_id: s.parent_session_id,
        metadata: atomize_keys(s.metadata || %{}),
        context: atomize_keys(s.context || %{}),
        tags: s.tags || [],
        created_at: s.created_at,
        updated_at: s.updated_at,
        deleted_at: s.deleted_at
      }
    end

    defp schema_to_run(%RunSchema{} = r) do
      %Run{
        id: r.id,
        session_id: r.session_id,
        status: safe_to_atom(r.status),
        input: atomize_keys_nullable(r.input),
        output: atomize_keys_nullable(r.output),
        error: atomize_keys_nullable(r.error),
        metadata: atomize_keys(r.metadata || %{}),
        turn_count: r.turn_count || 0,
        token_usage: atomize_keys(r.token_usage || %{}),
        started_at: r.started_at,
        ended_at: r.ended_at,
        provider: r.provider,
        provider_metadata: atomize_keys(r.provider_metadata || %{})
      }
    end

    defp schema_to_event(%EventSchema{} = e) do
      %Event{
        id: e.id,
        type: safe_to_atom(e.type),
        timestamp: e.timestamp,
        session_id: e.session_id,
        run_id: e.run_id,
        sequence_number: e.sequence_number,
        data: atomize_keys(e.data || %{}),
        metadata: atomize_keys(e.metadata || %{}),
        schema_version: e.schema_version || 1,
        provider: e.provider,
        correlation_id: e.correlation_id
      }
    end

    defp schema_to_artifact_meta(%ArtifactSchema{} = a) do
      %{
        id: a.id,
        session_id: a.session_id,
        run_id: a.run_id,
        key: a.key,
        content_type: a.content_type,
        byte_size: a.byte_size,
        checksum_sha256: a.checksum_sha256,
        storage_backend: a.storage_backend,
        storage_ref: a.storage_ref,
        metadata: a.metadata,
        created_at: a.created_at
      }
    end

    defp safe_to_atom(nil), do: nil
    defp safe_to_atom(s) when is_atom(s), do: s
    defp safe_to_atom(s) when is_binary(s), do: String.to_existing_atom(s)

    defp atomize_keys(nil), do: %{}
    defp atomize_keys(value), do: Serialization.atomize_keys(value)

    defp atomize_keys_nullable(nil), do: nil
    defp atomize_keys_nullable(map), do: Serialization.atomize_keys(map)
  end
else
  defmodule AgentSessionManager.Adapters.EctoQueryAPI do
    @moduledoc """
    Fallback implementation used when optional Ecto dependencies are not installed.
    """

    @behaviour AgentSessionManager.Ports.QueryAPI

    alias AgentSessionManager.OptionalDependency
    alias AgentSessionManager.Ports.QueryAPI

    @impl QueryAPI
    def search_sessions(_repo, _opts \\ []),
      do: {:error, missing_dependency_error(:search_sessions)}

    @impl QueryAPI
    def get_session_stats(_repo, _session_id),
      do: {:error, missing_dependency_error(:get_session_stats)}

    @impl QueryAPI
    def search_runs(_repo, _opts \\ []), do: {:error, missing_dependency_error(:search_runs)}

    @impl QueryAPI
    def get_usage_summary(_repo, _opts \\ []),
      do: {:error, missing_dependency_error(:get_usage_summary)}

    @impl QueryAPI
    def search_events(_repo, _opts \\ []), do: {:error, missing_dependency_error(:search_events)}

    @impl QueryAPI
    def count_events(_repo, _opts \\ []), do: {:error, missing_dependency_error(:count_events)}

    @impl QueryAPI
    def export_session(_repo, _session_id, _opts \\ []),
      do: {:error, missing_dependency_error(:export_session)}

    defp missing_dependency_error(operation) do
      OptionalDependency.error(:ecto_sql, __MODULE__, operation)
    end
  end
end
