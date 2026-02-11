if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Adapters.AshQueryAPI do
    @moduledoc """
    Ash-based implementation of the `QueryAPI` port.
    """

    @behaviour AgentSessionManager.Ports.QueryAPI

    import Ash.Expr
    require Ash.Query

    alias AgentSessionManager.Ash.Converters
    alias AgentSessionManager.Ash.Resources
    alias AgentSessionManager.Config
    alias AgentSessionManager.Core.{Error, Event, Serialization}

    @valid_session_statuses ~w(pending active paused completed failed cancelled)
    @valid_run_statuses ~w(pending running completed failed cancelled timeout)
    @valid_event_types Enum.map(Event.all_types(), &Atom.to_string/1)

    @impl true
    def search_sessions(domain, opts \\ []) do
      with :ok <- validate_limit(opts),
           :ok <- validate_status_filter(opts, @valid_session_statuses),
           {:ok, sessions} <- read_sessions(domain, opts) do
        sorted = sort_sessions(sessions, Keyword.get(opts, :order_by, :updated_at_desc))

        with {:ok, filtered} <- maybe_filter_sessions_by_cursor(sorted, opts, :session) do
          limited =
            maybe_take_limit(
              filtered,
              Keyword.get(opts, :limit, Config.get(:default_session_query_limit))
            )

          {:ok,
           %{
             sessions: limited,
             cursor:
               build_cursor(limited, :session, Keyword.get(opts, :order_by, :updated_at_desc)),
             total_count: length(sorted)
           }}
        end
      else
        {:error, %Error{} = error} -> {:error, error}
        {:error, reason} -> {:error, Error.new(:query_error, inspect(reason))}
      end
    end

    @impl true
    def get_session_stats(domain, session_id) do
      with {:ok, session} <- Ash.get(Resources.Session, session_id, domain: domain),
           false <- is_nil(session) do
        {:ok, runs} = read_runs(domain, session_id: session_id)
        {:ok, events} = read_events(domain, session_ids: [session_id])

        providers = runs |> Enum.map(& &1.provider) |> Enum.reject(&is_nil/1) |> Enum.uniq()

        status_counts =
          runs
          |> Enum.group_by(& &1.status)
          |> Map.new(fn {status, status_runs} -> {status, length(status_runs)} end)

        {:ok,
         %{
           event_count: length(events),
           run_count: length(runs),
           token_totals: reduce_token_totals(runs),
           providers_used: providers,
           first_event_at: events |> Enum.map(& &1.timestamp) |> Enum.min(fn -> nil end),
           last_event_at: events |> Enum.map(& &1.timestamp) |> Enum.max(fn -> nil end),
           status_counts: status_counts
         }}
      else
        true -> {:error, Error.new(:session_not_found, "Session #{session_id} not found")}
        {:error, reason} -> {:error, Error.new(:query_error, inspect(reason))}
      end
    end

    @impl true
    def search_runs(domain, opts \\ []) do
      with :ok <- validate_limit(opts),
           :ok <- validate_status_filter(opts, @valid_run_statuses),
           :ok <- validate_min_tokens(opts),
           {:ok, runs} <- read_runs(domain, opts) do
        order = Keyword.get(opts, :order_by, :started_at_desc)
        sorted = sort_runs(runs, order)

        with {:ok, filtered} <- maybe_filter_runs_by_cursor(sorted, opts, order) do
          limited =
            maybe_take_limit(
              filtered,
              Keyword.get(opts, :limit, Config.get(:default_run_query_limit))
            )

          {:ok, %{runs: limited, cursor: build_cursor(limited, :run, order)}}
        end
      else
        {:error, %Error{} = error} -> {:error, error}
        {:error, reason} -> {:error, Error.new(:query_error, inspect(reason))}
      end
    end

    @impl true
    def get_usage_summary(domain, opts \\ []) do
      with {:ok, runs} <- read_runs(domain, opts) do
        totals = reduce_token_totals(runs)

        by_provider =
          runs
          |> Enum.group_by(&(&1.provider || "unknown"))
          |> Map.new(fn {provider, provider_runs} ->
            {provider,
             reduce_token_totals(provider_runs)
             |> Map.put(:run_count, length(provider_runs))}
          end)

        {:ok,
         %{
           total_input_tokens: totals.input_tokens,
           total_output_tokens: totals.output_tokens,
           total_tokens: totals.total_tokens,
           run_count: length(runs),
           by_provider: by_provider
         }}
      end
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    @impl true
    def search_events(domain, opts \\ []) do
      with :ok <- validate_limit(opts),
           :ok <- validate_event_types_filter(opts),
           {:ok, events} <- read_events(domain, opts) do
        order = Keyword.get(opts, :order_by, :sequence_asc)
        sorted = sort_events(events, order)

        with {:ok, filtered} <- maybe_filter_events_by_cursor(sorted, opts, order) do
          limited =
            maybe_take_limit(
              filtered,
              Keyword.get(opts, :limit, Config.get(:default_event_query_limit))
            )

          {:ok, %{events: limited, cursor: build_cursor(limited, :event, order)}}
        end
      else
        {:error, %Error{} = error} -> {:error, error}
        {:error, reason} -> {:error, Error.new(:query_error, inspect(reason))}
      end
    end

    @impl true
    def count_events(domain, opts \\ []) do
      with :ok <- validate_event_types_filter(opts),
           {:ok, events} <- read_events(domain, opts) do
        {:ok, length(events)}
      end
    end

    @impl true
    def export_session(domain, session_id, opts \\ []) do
      case Ash.get(Resources.Session, session_id, domain: domain) do
        {:ok, nil} ->
          {:error, Error.new(:session_not_found, "Session #{session_id} not found")}

        {:ok, session} ->
          {:ok, runs} = read_runs(domain, session_id: session_id)
          {:ok, events} = read_events(domain, session_ids: [session_id])
          events = Enum.sort_by(events, &{&1.sequence_number || 0, &1.id}, :asc)

          export = %{session: Converters.record_to_session(session), runs: runs, events: events}

          export =
            if Keyword.get(opts, :include_artifacts, false) do
              artifacts =
                Resources.Artifact
                |> Ash.Query.for_read(:read)
                |> Ash.Query.filter(expr(session_id == ^session_id))
                |> then(&Ash.read!(&1, domain: domain))
                |> Enum.map(&artifact_to_meta/1)

              Map.put(export, :artifacts, artifacts)
            else
              export
            end

          {:ok, export}

        {:error, error} ->
          {:error, Error.new(:query_error, inspect(error))}
      end
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    defp read_sessions(domain, opts) do
      tags = normalize_tags_filter(opts)

      query =
        Resources.Session
        |> Ash.Query.for_read(:read)
        |> maybe_filter_session_agent(opts)
        |> maybe_filter_session_status(opts)
        |> maybe_filter_session_created_after(opts)
        |> maybe_filter_session_created_before(opts)
        |> maybe_filter_session_deleted(opts)

      sessions = Ash.read!(query, domain: domain) |> Enum.map(&Converters.record_to_session/1)

      sessions =
        case Keyword.get(opts, :provider) do
          nil -> sessions
          provider -> filter_sessions_by_provider(domain, sessions, provider)
        end

      sessions =
        if tags == [] do
          sessions
        else
          filter_sessions_by_tags(sessions, tags)
        end

      {:ok, sessions}
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    defp read_runs(domain, opts) do
      query =
        Resources.Run
        |> Ash.Query.for_read(:read)
        |> maybe_filter_run_session(opts)
        |> maybe_filter_run_provider(opts)
        |> maybe_filter_run_status(opts)
        |> maybe_filter_run_started_after(opts)
        |> maybe_filter_run_started_before(opts)
        |> maybe_filter_usage_since(opts)
        |> maybe_filter_usage_until(opts)

      runs =
        query
        |> Ash.read!(domain: domain)
        |> Enum.map(&Converters.record_to_run/1)
        |> maybe_filter_run_min_tokens(opts)

      {:ok, runs}
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    defp read_events(domain, opts) do
      query =
        Resources.Event
        |> Ash.Query.for_read(:read)
        |> maybe_filter_event_sessions(opts)
        |> maybe_filter_event_runs(opts)
        |> maybe_filter_event_types(opts)
        |> maybe_filter_event_providers(opts)
        |> maybe_filter_event_since(opts)
        |> maybe_filter_event_until(opts)
        |> maybe_filter_event_correlation(opts)

      {:ok, Ash.read!(query, domain: domain) |> Enum.map(&Converters.record_to_event/1)}
    rescue
      e -> {:error, Error.new(:query_error, Exception.message(e))}
    end

    defp maybe_filter_session_agent(query, opts) do
      case Keyword.get(opts, :agent_id) do
        nil -> query
        agent_id -> Ash.Query.filter(query, expr(agent_id == ^agent_id))
      end
    end

    defp maybe_filter_session_status(query, opts) do
      case Keyword.get(opts, :status) do
        nil ->
          query

        statuses when is_list(statuses) ->
          Ash.Query.filter(query, expr(status in ^Enum.map(statuses, &to_string/1)))

        status ->
          Ash.Query.filter(query, expr(status == ^to_string(status)))
      end
    end

    defp maybe_filter_session_created_after(query, opts) do
      case Keyword.get(opts, :created_after) do
        nil -> query
        dt -> Ash.Query.filter(query, expr(created_at >= ^dt))
      end
    end

    defp maybe_filter_session_created_before(query, opts) do
      case Keyword.get(opts, :created_before) do
        nil -> query
        dt -> Ash.Query.filter(query, expr(created_at <= ^dt))
      end
    end

    defp maybe_filter_session_deleted(query, opts) do
      if Keyword.get(opts, :include_deleted, false) do
        query
      else
        Ash.Query.filter(query, expr(is_nil(deleted_at)))
      end
    end

    defp maybe_filter_run_session(query, opts) do
      case Keyword.get(opts, :session_id) do
        nil -> query
        sid -> Ash.Query.filter(query, expr(session_id == ^sid))
      end
    end

    defp maybe_filter_run_provider(query, opts) do
      case Keyword.get(opts, :provider) do
        nil -> query
        provider -> Ash.Query.filter(query, expr(provider == ^provider))
      end
    end

    defp maybe_filter_run_status(query, opts) do
      case Keyword.get(opts, :status) do
        nil ->
          query

        statuses when is_list(statuses) ->
          Ash.Query.filter(query, expr(status in ^Enum.map(statuses, &to_string/1)))

        status ->
          Ash.Query.filter(query, expr(status == ^to_string(status)))
      end
    end

    defp maybe_filter_run_started_after(query, opts) do
      case Keyword.get(opts, :started_after) do
        nil -> query
        dt -> Ash.Query.filter(query, expr(started_at >= ^dt))
      end
    end

    defp maybe_filter_run_started_before(query, opts) do
      case Keyword.get(opts, :started_before) do
        nil -> query
        dt -> Ash.Query.filter(query, expr(started_at <= ^dt))
      end
    end

    defp maybe_filter_usage_since(query, opts) do
      case Keyword.get(opts, :since) do
        nil -> query
        dt -> Ash.Query.filter(query, expr(started_at >= ^dt))
      end
    end

    defp maybe_filter_usage_until(query, opts) do
      case Keyword.get(opts, :until) do
        nil -> query
        dt -> Ash.Query.filter(query, expr(started_at <= ^dt))
      end
    end

    defp maybe_filter_event_sessions(query, opts) do
      case Keyword.get(opts, :session_ids) do
        nil -> query
        [] -> query
        ids -> Ash.Query.filter(query, expr(session_id in ^ids))
      end
    end

    defp maybe_filter_event_runs(query, opts) do
      case Keyword.get(opts, :run_ids) do
        nil -> query
        [] -> query
        ids -> Ash.Query.filter(query, expr(run_id in ^ids))
      end
    end

    defp maybe_filter_event_types(query, opts) do
      case Keyword.get(opts, :types) do
        nil ->
          query

        types when is_list(types) ->
          Ash.Query.filter(query, expr(type in ^Enum.map(types, &to_string/1)))

        type ->
          Ash.Query.filter(query, expr(type == ^to_string(type)))
      end
    end

    defp maybe_filter_event_providers(query, opts) do
      case Keyword.get(opts, :providers) do
        nil -> query
        [] -> query
        providers -> Ash.Query.filter(query, expr(provider in ^providers))
      end
    end

    defp maybe_filter_event_since(query, opts) do
      case Keyword.get(opts, :since) do
        nil -> query
        dt -> Ash.Query.filter(query, expr(timestamp >= ^dt))
      end
    end

    defp maybe_filter_event_until(query, opts) do
      case Keyword.get(opts, :until) do
        nil -> query
        dt -> Ash.Query.filter(query, expr(timestamp <= ^dt))
      end
    end

    defp maybe_filter_event_correlation(query, opts) do
      case Keyword.get(opts, :correlation_id) do
        nil -> query
        cid -> Ash.Query.filter(query, expr(correlation_id == ^cid))
      end
    end

    defp validate_status_filter(opts, allowed) do
      case Keyword.get(opts, :status) do
        nil ->
          :ok

        [] ->
          :ok

        values ->
          values |> List.wrap() |> Enum.reduce_while(:ok, &check_status_value(&1, &2, allowed))
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
          if limit <= max do
            :ok
          else
            {:error, Error.new(:validation_error, "limit must be <= #{max}")}
          end

        _ ->
          {:error, Error.new(:validation_error, "limit must be a positive integer")}
      end
    end

    defp check_status_value(value, :ok, allowed) do
      case normalize_filter_value(value, "status") do
        {:ok, normalized} ->
          if normalized in allowed do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              Error.new(
                :validation_error,
                "status contains unsupported value: #{inspect(value)}"
              )}}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end

    defp validate_event_types_filter(opts) do
      case Keyword.get(opts, :types) do
        nil -> :ok
        [] -> :ok
        values -> values |> List.wrap() |> Enum.reduce_while(:ok, &check_event_type_value/2)
      end
    end

    defp check_event_type_value(value, :ok) do
      case normalize_filter_value(value, "types") do
        {:ok, normalized} when normalized in @valid_event_types ->
          {:cont, :ok}

        {:ok, _} ->
          {:halt,
           {:error,
            Error.new(
              :validation_error,
              "types contains unsupported value: #{inspect(value)}"
            )}}

        {:error, _} = error ->
          {:halt, error}
      end
    end

    defp normalize_filter_value(value, _field) when is_atom(value),
      do: {:ok, Atom.to_string(value)}

    defp normalize_filter_value(value, _field) when is_binary(value), do: {:ok, value}

    defp normalize_filter_value(_value, field),
      do: {:error, Error.new(:validation_error, "#{field} values must be atoms or strings")}

    defp reduce_token_totals(runs) do
      Enum.reduce(runs, %{input_tokens: 0, output_tokens: 0, total_tokens: 0}, fn run, acc ->
        usage = run.token_usage || %{}

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

    defp maybe_filter_run_min_tokens(runs, opts) do
      case Keyword.get(opts, :min_tokens) do
        nil ->
          runs

        min_tokens when is_integer(min_tokens) ->
          Enum.filter(runs, fn run ->
            get_token_val(run.token_usage || %{}, "total_tokens") >= min_tokens
          end)
      end
    end

    defp filter_sessions_by_provider(domain, sessions, provider) do
      session_ids = Enum.map(sessions, & &1.id)

      provider_session_ids =
        Resources.Run
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(expr(session_id in ^session_ids and provider == ^to_string(provider)))
        |> Ash.read!(domain: domain)
        |> Enum.map(& &1.session_id)
        |> MapSet.new()

      Enum.filter(sessions, &MapSet.member?(provider_session_ids, &1.id))
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

    defp sort_sessions(sessions, :created_at_asc),
      do: Enum.sort_by(sessions, &{&1.created_at, &1.id}, :asc)

    defp sort_sessions(sessions, :created_at_desc),
      do: Enum.sort_by(sessions, &{&1.created_at, &1.id}, :desc)

    defp sort_sessions(sessions, _), do: Enum.sort_by(sessions, &{&1.updated_at, &1.id}, :desc)

    defp sort_runs(runs, :started_at_asc), do: Enum.sort_by(runs, &{&1.started_at, &1.id}, :asc)

    defp sort_runs(runs, :token_usage_desc),
      do: Enum.sort_by(runs, &get_token_val(&1.token_usage || %{}, "total_tokens"), :desc)

    defp sort_runs(runs, _), do: Enum.sort_by(runs, &{&1.started_at, &1.id}, :desc)

    defp sort_events(events, :timestamp_asc),
      do: Enum.sort_by(events, &{&1.timestamp, &1.id}, :asc)

    defp sort_events(events, :timestamp_desc),
      do: Enum.sort_by(events, &{&1.timestamp, &1.id}, :desc)

    defp sort_events(events, _), do: Enum.sort_by(events, &{&1.sequence_number || 0, &1.id}, :asc)

    defp maybe_take_limit(list, limit) when is_integer(limit) and limit > 0,
      do: Enum.take(list, limit)

    defp maybe_take_limit(list, _), do: list

    defp maybe_filter_sessions_by_cursor(list, opts, type),
      do: maybe_filter_by_cursor(list, opts, type)

    defp maybe_filter_runs_by_cursor(list, opts, _order),
      do: maybe_filter_by_cursor(list, opts, :run)

    defp maybe_filter_events_by_cursor(list, opts, _order),
      do: maybe_filter_by_cursor(list, opts, :event)

    defp maybe_filter_by_cursor(list, opts, type) do
      case Keyword.get(opts, :cursor) do
        nil ->
          {:ok, list}

        cursor ->
          case decode_cursor(cursor, type) do
            {:ok, %{id: cursor_id}} ->
              {:ok, drop_after_cursor_id(list, cursor_id)}

            {:error, %Error{} = error} ->
              {:error, error}
          end
      end
    end

    defp drop_after_cursor_id(list, cursor_id) do
      case Enum.find_index(list, &(&1.id == cursor_id)) do
        idx when is_integer(idx) -> Enum.drop(list, idx + 1)
        nil -> list
      end
    end

    defp artifact_to_meta(schema) do
      %{
        id: schema.id,
        session_id: schema.session_id,
        run_id: schema.run_id,
        key: schema.key,
        content_type: schema.content_type,
        byte_size: schema.byte_size,
        checksum_sha256: schema.checksum_sha256,
        storage_backend: schema.storage_backend,
        storage_ref: schema.storage_ref,
        metadata: schema.metadata,
        created_at: schema.created_at
      }
    end

    defp build_cursor([], _type, _order_by), do: nil

    defp build_cursor(items, type, order_by) do
      last = List.last(items)
      encode_cursor({type, order_by, sort_value(type, order_by, last), last.id})
    end

    defp sort_value(:session, :created_at_asc, item), do: item.created_at
    defp sort_value(:session, :created_at_desc, item), do: item.created_at
    defp sort_value(:session, _order, item), do: item.updated_at
    defp sort_value(:run, _order, item), do: item.started_at
    defp sort_value(:event, :timestamp_asc, item), do: item.timestamp
    defp sort_value(:event, :timestamp_desc, item), do: item.timestamp
    defp sort_value(:event, _order, item), do: item.sequence_number

    defp encode_cursor(term), do: term |> :erlang.term_to_binary() |> Base.url_encode64()

    defp decode_cursor(cursor, type) when is_binary(cursor) do
      with {:ok, binary} <- Base.url_decode64(cursor),
           {^type, order_by, sort_value, id} <- :erlang.binary_to_term(binary, [:safe]),
           true <- is_binary(id) do
        {:ok, %{order_by: order_by, sort_value: sort_value, id: id}}
      else
        _ -> {:error, Error.new(:invalid_cursor, "Invalid cursor")}
      end
    rescue
      _ -> {:error, Error.new(:invalid_cursor, "Invalid cursor")}
    end
  end
else
  defmodule AgentSessionManager.Ash.Adapters.AshQueryAPI do
    @moduledoc """
    Fallback implementation used when optional Ash dependencies are not installed.
    """

    @behaviour AgentSessionManager.Ports.QueryAPI
    alias AgentSessionManager.OptionalDependency

    @impl true
    def search_sessions(_domain, _opts \\ []), do: {:error, missing_dep_error(:search_sessions)}

    @impl true
    def get_session_stats(_domain, _session_id),
      do: {:error, missing_dep_error(:get_session_stats)}

    @impl true
    def search_runs(_domain, _opts \\ []), do: {:error, missing_dep_error(:search_runs)}

    @impl true
    def get_usage_summary(_domain, _opts \\ []),
      do: {:error, missing_dep_error(:get_usage_summary)}

    @impl true
    def search_events(_domain, _opts \\ []), do: {:error, missing_dep_error(:search_events)}

    @impl true
    def count_events(_domain, _opts \\ []), do: {:error, missing_dep_error(:count_events)}

    @impl true
    def export_session(_domain, _session_id, _opts \\ []),
      do: {:error, missing_dep_error(:export_session)}

    defp missing_dep_error(op), do: OptionalDependency.error(:ash, __MODULE__, op)
  end
end
