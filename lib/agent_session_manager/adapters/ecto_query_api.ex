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

    alias AgentSessionManager.Adapters.EctoSessionStore.Converters
    alias AgentSessionManager.Config
    alias AgentSessionManager.Core.{Error, Event, Serialization}
    alias AgentSessionManager.Cost.CostCalculator
    alias AgentSessionManager.Ports.QueryAPI

    alias AgentSessionManager.Adapters.EctoSessionStore.Schemas.{
      ArtifactSchema,
      EventSchema,
      RunSchema,
      SessionSchema
    }

    @valid_session_statuses ~w(pending active paused completed failed cancelled)
    @valid_run_statuses ~w(pending running completed failed cancelled timeout)
    @valid_event_types Enum.map(Event.all_types(), &Atom.to_string/1)

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
    def get_cost_summary(repo, opts \\ []), do: do_get_cost_summary(repo, opts)

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
      with :ok <- validate_limit(opts),
           :ok <- validate_session_status_filter(opts) do
        limit = Keyword.get(opts, :limit, Config.get(:default_session_query_limit))
        tags = normalize_tags_filter(opts)
        order_by = normalize_session_order(Keyword.get(opts, :order_by, :updated_at_desc))
        opts = Keyword.put(opts, :order_by, order_by)

        base_query =
          SessionSchema
          |> apply_session_filters(opts)
          |> apply_session_order(opts)

        case apply_cursor(base_query, opts, :session, order_by) do
          {:ok, page_query} ->
            {sessions, total_count} =
              build_session_page(repo, base_query, page_query, opts, tags, limit)

            cursor = build_cursor(sessions, :session, order_by)
            {:ok, %{sessions: sessions, cursor: cursor, total_count: total_count}}

          {:error, %Error{} = error} ->
            {:error, error}
        end
      end
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    defp apply_session_filters(query, opts) do
      query
      |> filter_by_opt(:agent_id, opts)
      |> filter_session_status(opts)
      |> filter_session_provider(opts)
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

    defp filter_session_provider(query, opts) do
      case Keyword.get(opts, :provider) do
        nil ->
          query

        providers ->
          provider_list =
            providers
            |> List.wrap()
            |> Enum.map(&to_string/1)

          where(
            query,
            [s],
            s.id in subquery(
              from(r in RunSchema,
                where: r.provider in ^provider_list,
                select: r.session_id
              )
            )
          )
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

    defp normalize_tags_filter(opts) do
      case Keyword.get(opts, :tags) do
        nil -> []
        [] -> []
        tags -> Enum.map(tags, &to_string/1)
      end
    end

    defp filter_sessions_by_tags(sessions, tags) do
      Enum.filter(sessions, fn session ->
        session_tags = Enum.map(session.tags || [], &to_string/1)
        Enum.all?(tags, &(&1 in session_tags))
      end)
    end

    defp build_session_page(repo, _base_query, page_query, opts, [], limit) do
      query = page_query |> limit(^limit)
      count_query = SessionSchema |> apply_session_filters(opts) |> select([s], count(s.id))

      sessions = repo.all(query) |> Enum.map(&schema_to_session/1)
      total_count = repo.one(count_query)
      {sessions, total_count}
    end

    defp build_session_page(repo, base_query, page_query, _opts, tags, limit) do
      total_sessions =
        base_query
        |> repo.all()
        |> Enum.map(&schema_to_session/1)
        |> filter_sessions_by_tags(tags)

      sessions =
        page_query
        |> repo.all()
        |> Enum.map(&schema_to_session/1)
        |> filter_sessions_by_tags(tags)
        |> Enum.take(limit)

      total_count = length(total_sessions)
      {sessions, total_count}
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
      limit = Keyword.get(opts, :limit, Config.get(:default_run_query_limit))
      order_by = normalize_run_order(Keyword.get(opts, :order_by, :started_at_desc))
      opts = Keyword.put(opts, :order_by, order_by)

      with :ok <- validate_limit(opts),
           :ok <- validate_run_status_filter(opts),
           :ok <- ensure_token_usage_support(repo, opts),
           :ok <- validate_min_tokens(opts),
           {:ok, query_with_cursor} <-
             apply_cursor(
               RunSchema
               |> apply_run_filters(repo, opts)
               |> apply_run_order(repo, opts),
               opts,
               :run,
               order_by
             ) do
        query = query_with_cursor |> limit(^limit)

        runs = repo.all(query) |> Enum.map(&schema_to_run/1)
        cursor = build_cursor(runs, :run, order_by)

        {:ok, %{runs: runs, cursor: cursor}}
      else
        {:error, %Error{} = error} -> {:error, error}
      end
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    defp apply_run_filters(query, repo, opts) do
      query
      |> filter_run_session(opts)
      |> filter_run_provider(opts)
      |> filter_run_status(opts)
      |> filter_started_after(opts)
      |> filter_started_before(opts)
      |> filter_run_min_tokens(repo, opts)
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

    defp apply_run_order(query, repo, opts) do
      case Keyword.get(opts, :order_by, :started_at_desc) do
        :started_at_asc ->
          order_by(query, [r], asc: r.started_at, asc: r.id)

        :started_at_desc ->
          order_by(query, [r], desc: r.started_at, desc: r.id)

        :token_usage_desc ->
          case repo.__adapter__() do
            Ecto.Adapters.SQLite3 ->
              order_by(query, [r],
                desc: fragment("COALESCE(json_extract(?, '$.total_tokens'), 0)", r.token_usage),
                desc: r.id
              )

            Ecto.Adapters.Postgres ->
              order_by(query, [r],
                desc: fragment("COALESCE((?->>'total_tokens')::int, 0)", r.token_usage),
                desc: r.id
              )
          end

        _ ->
          order_by(query, [r], desc: r.started_at, desc: r.id)
      end
    end

    defp filter_run_min_tokens(query, repo, opts) do
      case Keyword.get(opts, :min_tokens) do
        nil ->
          query

        min_tokens when is_integer(min_tokens) ->
          case repo.__adapter__() do
            Ecto.Adapters.SQLite3 ->
              where(
                query,
                [r],
                fragment("COALESCE(json_extract(?, '$.total_tokens'), 0)", r.token_usage) >=
                  ^min_tokens
              )

            Ecto.Adapters.Postgres ->
              where(
                query,
                [r],
                fragment("COALESCE((?->>'total_tokens')::int, 0)", r.token_usage) >=
                  ^min_tokens
              )
          end
      end
    end

    defp ensure_token_usage_support(repo, opts) do
      if requires_token_usage_filter?(opts) and not token_usage_supported?(repo) do
        {:error,
         Error.new(
           :query_error,
           "token usage filters require SQLite or PostgreSQL adapters"
         )}
      else
        :ok
      end
    end

    defp validate_min_tokens(opts) do
      case Keyword.get(opts, :min_tokens) do
        nil -> :ok
        min when is_integer(min) and min >= 0 -> :ok
        _ -> {:error, Error.new(:query_error, "min_tokens must be a non-negative integer")}
      end
    end

    defp validate_limit(opts) do
      max = Config.get(:max_query_limit)

      case Keyword.get(opts, :limit) do
        nil ->
          :ok

        limit when is_integer(limit) and limit > 0 ->
          if limit <= max,
            do: :ok,
            else: {:error, Error.new(:validation_error, "limit must be <= #{max}")}

        _limit ->
          {:error, Error.new(:validation_error, "limit must be a positive integer")}
      end
    end

    defp validate_session_status_filter(opts) do
      validate_allowed_filter_values(
        Keyword.get(opts, :status),
        @valid_session_statuses,
        "status"
      )
    end

    defp validate_run_status_filter(opts) do
      validate_allowed_filter_values(Keyword.get(opts, :status), @valid_run_statuses, "status")
    end

    defp validate_event_types_filter(opts) do
      validate_allowed_filter_values(Keyword.get(opts, :types), @valid_event_types, "types")
    end

    defp validate_allowed_filter_values(nil, _allowed_values, _field_name), do: :ok
    defp validate_allowed_filter_values([], _allowed_values, _field_name), do: :ok

    defp validate_allowed_filter_values(values, allowed_values, field_name) do
      values
      |> List.wrap()
      |> Enum.reduce_while(:ok, fn value, :ok ->
        with {:ok, normalized} <- normalize_filter_value(value, field_name),
             true <- normalized in allowed_values do
          {:cont, :ok}
        else
          {:error, %Error{} = error} ->
            {:halt, {:error, error}}

          false ->
            {:halt,
             {:error,
              Error.new(
                :validation_error,
                "#{field_name} contains unsupported value: #{inspect(value)}"
              )}}
        end
      end)
    end

    defp normalize_filter_value(value, _field_name) when is_atom(value),
      do: {:ok, Atom.to_string(value)}

    defp normalize_filter_value(value, _field_name) when is_binary(value), do: {:ok, value}

    defp normalize_filter_value(_value, field_name) do
      {:error, Error.new(:validation_error, "#{field_name} values must be atoms or strings")}
    end

    defp requires_token_usage_filter?(opts) do
      Keyword.has_key?(opts, :min_tokens) or Keyword.get(opts, :order_by) == :token_usage_desc
    end

    defp token_usage_supported?(repo) do
      case repo.__adapter__() do
        Ecto.Adapters.SQLite3 -> true
        Ecto.Adapters.Postgres -> true
        _ -> false
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

    defp do_get_cost_summary(repo, opts) do
      pricing_table =
        Keyword.get(
          opts,
          :pricing_table,
          Application.get_env(
            :agent_session_manager,
            :pricing_table,
            CostCalculator.default_pricing_table()
          )
        )

      query =
        RunSchema
        |> apply_usage_filters(opts)
        |> apply_cost_agent_filter(opts)

      runs =
        repo.all(
          from(r in query,
            select: %{
              provider: r.provider,
              token_usage: r.token_usage,
              provider_metadata: r.provider_metadata,
              cost_usd: r.cost_usd
            }
          )
        )

      {total_cost, by_provider, by_model, unmapped} =
        Enum.reduce(runs, {0.0, %{}, %{}, 0}, fn run_data, {total, providers, models, unmapped} ->
          cost = run_data.cost_usd || calculate_post_hoc_cost(run_data, pricing_table)

          if is_number(cost) do
            provider = run_data.provider || "unknown"
            model = provider_model_name(run_data.provider_metadata)
            usage = run_data.token_usage || %{}

            provider_entry = Map.get(providers, provider, %{cost_usd: 0.0, run_count: 0})

            updated_provider = %{
              provider_entry
              | cost_usd: provider_entry.cost_usd + cost,
                run_count: provider_entry.run_count + 1
            }

            model_entry =
              Map.get(models, model, %{cost_usd: 0.0, input_tokens: 0, output_tokens: 0})

            updated_model = %{
              model_entry
              | cost_usd: model_entry.cost_usd + cost,
                input_tokens: model_entry.input_tokens + get_token_val(usage, "input_tokens"),
                output_tokens: model_entry.output_tokens + get_token_val(usage, "output_tokens")
            }

            {total + cost, Map.put(providers, provider, updated_provider),
             Map.put(models, model, updated_model), unmapped}
          else
            {total, providers, models, unmapped + 1}
          end
        end)

      {:ok,
       %{
         total_cost_usd: total_cost,
         run_count: length(runs),
         by_provider: by_provider,
         by_model: by_model,
         unmapped_runs: unmapped
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

    defp apply_cost_agent_filter(query, opts) do
      case Keyword.get(opts, :agent_id) do
        nil ->
          query

        agent_id ->
          from(r in query,
            join: s in SessionSchema,
            on: r.session_id == s.id,
            where: s.agent_id == ^agent_id
          )
      end
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

    defp calculate_post_hoc_cost(run_data, pricing_table) do
      token_usage = run_data.token_usage || %{}
      provider = run_data.provider
      model = fetch_metadata_value(run_data.provider_metadata, :model)

      case CostCalculator.calculate(token_usage, provider, model, pricing_table) do
        {:ok, cost} -> cost
        {:error, _} -> nil
      end
    end

    defp provider_model_name(provider_metadata) do
      fetch_metadata_value(provider_metadata, :model) || "unknown"
    end

    defp fetch_metadata_value(map, key) when is_map(map) and is_atom(key) do
      Map.get(map, key) || Map.get(map, Atom.to_string(key))
    end

    defp fetch_metadata_value(_map, _key), do: nil

    # ============================================================================
    # Search Events
    # ============================================================================

    defp do_search_events(repo, opts) do
      with :ok <- validate_limit(opts),
           :ok <- validate_event_types_filter(opts) do
        limit = Keyword.get(opts, :limit, Config.get(:default_event_query_limit))
        order_by = normalize_event_order(Keyword.get(opts, :order_by, :sequence_asc))
        opts = Keyword.put(opts, :order_by, order_by)

        case apply_cursor(
               EventSchema
               |> apply_event_filters(opts)
               |> apply_event_order(opts),
               opts,
               :event,
               order_by
             ) do
          {:ok, query_with_cursor} ->
            query = query_with_cursor |> limit(^limit)

            events = repo.all(query) |> Enum.map(&schema_to_event/1)
            cursor = build_cursor(events, :event, order_by)

            {:ok, %{events: events, cursor: cursor}}

          {:error, %Error{} = error} ->
            {:error, error}
        end
      end
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    defp do_count_events(repo, opts) do
      with :ok <- validate_event_types_filter(opts) do
        count =
          EventSchema
          |> apply_event_filters(opts)
          |> select([e], count(e.id))
          |> repo.one()

        {:ok, count}
      end
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

    defp apply_cursor(query, opts, type, order_by) do
      case Keyword.get(opts, :cursor) do
        nil ->
          {:ok, query}

        cursor ->
          with {:ok, parsed_cursor} <- decode_cursor(cursor, type),
               :ok <- validate_cursor_order(type, order_by, parsed_cursor.order_by),
               {:ok, _} = query_with_cursor <-
                 apply_keyset_cursor(
                   query,
                   type,
                   order_by,
                   parsed_cursor.sort_value,
                   parsed_cursor.id
                 ) do
            query_with_cursor
          end
      end
    end

    defp build_cursor([], _type, _order_by), do: nil

    defp build_cursor(items, :session, order_by) do
      last = List.last(items)

      sort_value =
        case normalize_session_order(order_by) do
          :created_at_asc -> last.created_at
          :created_at_desc -> last.created_at
          :updated_at_desc -> last.updated_at
        end

      encode_cursor({:session, normalize_session_order(order_by), sort_value, last.id})
    end

    defp build_cursor(items, :run, order_by) do
      last = List.last(items)

      case normalize_run_order(order_by) do
        :token_usage_desc ->
          nil

        normalized_order ->
          encode_cursor({:run, normalized_order, last.started_at, last.id})
      end
    end

    defp build_cursor(items, :event, order_by) do
      last = List.last(items)

      sort_value =
        case normalize_event_order(order_by) do
          :sequence_asc -> last.sequence_number
          :timestamp_asc -> last.timestamp
          :timestamp_desc -> last.timestamp
        end

      encode_cursor({:event, normalize_event_order(order_by), sort_value, last.id})
    end

    defp decode_cursor(cursor, type) when is_binary(cursor) do
      with {:ok, binary} <- decode_cursor_binary(cursor),
           {:ok, term} <- decode_cursor_term(binary),
           {:ok, _} = parsed <- normalize_cursor_term(term, type),
           do: parsed
    end

    defp decode_cursor(_cursor, _type) do
      {:error, Error.new(:invalid_cursor, "Cursor must be a non-empty string")}
    end

    defp decode_cursor_binary(cursor) do
      case Base.url_decode64(cursor) do
        {:ok, decoded} ->
          {:ok, decoded}

        :error ->
          case Base.url_decode64(cursor, padding: false) do
            {:ok, decoded} -> {:ok, decoded}
            :error -> {:error, Error.new(:invalid_cursor, "Cursor is not valid Base64")}
          end
      end
    end

    defp decode_cursor_term(binary) do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    rescue
      _ ->
        {:error, Error.new(:invalid_cursor, "Cursor payload could not be decoded")}
    end

    defp normalize_cursor_term({:session, order_by, sort_value, id}, :session)
         when is_atom(order_by) and is_binary(id) do
      {:ok, %{order_by: order_by, sort_value: sort_value, id: id}}
    end

    defp normalize_cursor_term({:session, sort_value, id}, :session) when is_binary(id) do
      {:ok, %{order_by: nil, sort_value: sort_value, id: id}}
    end

    defp normalize_cursor_term({:run, order_by, sort_value, id}, :run)
         when is_atom(order_by) and is_binary(id) do
      {:ok, %{order_by: order_by, sort_value: sort_value, id: id}}
    end

    defp normalize_cursor_term({:run, sort_value, id}, :run) when is_binary(id) do
      {:ok, %{order_by: nil, sort_value: sort_value, id: id}}
    end

    defp normalize_cursor_term({:event, order_by, sort_value, id}, :event)
         when is_atom(order_by) and is_binary(id) do
      {:ok, %{order_by: order_by, sort_value: sort_value, id: id}}
    end

    defp normalize_cursor_term({:event, sort_value, id}, :event) when is_binary(id) do
      {:ok, %{order_by: nil, sort_value: sort_value, id: id}}
    end

    defp normalize_cursor_term(_term, _type) do
      {:error, Error.new(:invalid_cursor, "Cursor does not match expected format")}
    end

    defp validate_cursor_order(type, requested_order, nil) do
      if requested_order == default_order(type) do
        :ok
      else
        {:error,
         Error.new(
           :invalid_cursor,
           "Cursor order does not match requested order_by"
         )}
      end
    end

    defp validate_cursor_order(_type, requested_order, requested_order), do: :ok

    defp validate_cursor_order(_type, _requested_order, _cursor_order) do
      {:error, Error.new(:invalid_cursor, "Cursor order does not match requested order_by")}
    end

    defp apply_keyset_cursor(query, :session, order_by, sort_value, id) do
      apply_session_keyset_cursor(query, order_by, sort_value, id)
    end

    defp apply_keyset_cursor(query, :run, order_by, sort_value, id) do
      apply_run_keyset_cursor(query, order_by, sort_value, id)
    end

    defp apply_keyset_cursor(query, :event, order_by, sort_value, id) do
      apply_event_keyset_cursor(query, order_by, sort_value, id)
    end

    defp apply_session_keyset_cursor(query, order_by, %DateTime{} = sort_value, id)
         when is_binary(id) do
      case normalize_session_order(order_by) do
        :created_at_asc ->
          apply_session_created_cursor(query, :asc, sort_value, id)

        :created_at_desc ->
          apply_session_created_cursor(query, :desc, sort_value, id)

        :updated_at_desc ->
          apply_session_updated_cursor(query, :desc, sort_value, id)
      end
    end

    defp apply_session_keyset_cursor(_query, _order_by, _sort_value, _id) do
      {:error, Error.new(:invalid_cursor, "Session cursor has invalid sort value")}
    end

    defp apply_session_created_cursor(query, :asc, sort_value, id) do
      {:ok,
       where(
         query,
         [s],
         s.created_at > ^sort_value or (s.created_at == ^sort_value and s.id > ^id)
       )}
    end

    defp apply_session_created_cursor(query, :desc, sort_value, id) do
      {:ok,
       where(
         query,
         [s],
         s.created_at < ^sort_value or (s.created_at == ^sort_value and s.id < ^id)
       )}
    end

    defp apply_session_updated_cursor(query, :desc, sort_value, id) do
      {:ok,
       where(
         query,
         [s],
         s.updated_at < ^sort_value or (s.updated_at == ^sort_value and s.id < ^id)
       )}
    end

    defp apply_run_keyset_cursor(query, order_by, %DateTime{} = sort_value, id)
         when is_binary(id) do
      case normalize_run_order(order_by) do
        :started_at_asc ->
          {:ok,
           where(
             query,
             [r],
             r.started_at > ^sort_value or (r.started_at == ^sort_value and r.id > ^id)
           )}

        :started_at_desc ->
          {:ok,
           where(
             query,
             [r],
             r.started_at < ^sort_value or (r.started_at == ^sort_value and r.id < ^id)
           )}

        :token_usage_desc ->
          {:error,
           Error.new(
             :invalid_cursor,
             "Cursor pagination is not supported for order_by :token_usage_desc"
           )}
      end
    end

    defp apply_run_keyset_cursor(_query, _order_by, _sort_value, _id) do
      {:error, Error.new(:invalid_cursor, "Run cursor has invalid sort value")}
    end

    defp apply_event_keyset_cursor(query, :sequence_asc, sort_value, id)
         when is_integer(sort_value) and is_binary(id) do
      {:ok,
       where(
         query,
         [e],
         e.sequence_number > ^sort_value or (e.sequence_number == ^sort_value and e.id > ^id)
       )}
    end

    defp apply_event_keyset_cursor(query, :timestamp_asc, %DateTime{} = sort_value, id)
         when is_binary(id) do
      {:ok,
       where(
         query,
         [e],
         e.timestamp > ^sort_value or (e.timestamp == ^sort_value and e.id > ^id)
       )}
    end

    defp apply_event_keyset_cursor(query, :timestamp_desc, %DateTime{} = sort_value, id)
         when is_binary(id) do
      {:ok,
       where(
         query,
         [e],
         e.timestamp < ^sort_value or (e.timestamp == ^sort_value and e.id < ^id)
       )}
    end

    defp apply_event_keyset_cursor(_query, _order_by, _sort_value, _id) do
      {:error, Error.new(:invalid_cursor, "Event cursor has invalid sort value")}
    end

    defp default_order(:session), do: :updated_at_desc
    defp default_order(:run), do: :started_at_desc
    defp default_order(:event), do: :sequence_asc

    defp normalize_session_order(order_by)
         when order_by in [:created_at_asc, :created_at_desc, :updated_at_desc],
         do: order_by

    defp normalize_session_order(_order_by), do: :updated_at_desc

    defp normalize_run_order(order_by)
         when order_by in [:started_at_asc, :started_at_desc, :token_usage_desc],
         do: order_by

    defp normalize_run_order(_order_by), do: :started_at_desc

    defp normalize_event_order(order_by)
         when order_by in [:sequence_asc, :timestamp_asc, :timestamp_desc],
         do: order_by

    defp normalize_event_order(_order_by), do: :sequence_asc

    defp encode_cursor(term) do
      term |> :erlang.term_to_binary() |> Base.url_encode64()
    end

    # ============================================================================
    # Schema conversion (shared with EctoSessionStore)
    # ============================================================================

    defp schema_to_session(schema), do: Converters.schema_to_session(schema)
    defp schema_to_run(schema), do: Converters.schema_to_run(schema)
    defp schema_to_event(schema), do: Converters.schema_to_event(schema)
    defp schema_to_artifact_meta(schema), do: Converters.schema_to_artifact_meta(schema)

    defp safe_to_atom(nil), do: nil
    defp safe_to_atom(value) when is_atom(value), do: value
    defp safe_to_atom(value) when is_binary(value), do: String.to_existing_atom(value)
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
    def get_cost_summary(_repo, _opts \\ []),
      do: {:error, missing_dependency_error(:get_cost_summary)}

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
