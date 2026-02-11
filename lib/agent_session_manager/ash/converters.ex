if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Converters do
    @moduledoc false

    alias AgentSessionManager.Core.{Event, Run, Serialization, Session}

    @spec record_to_session(map() | struct()) :: Session.t()
    def record_to_session(record) do
      %Session{
        id: field(record, :id),
        agent_id: field(record, :agent_id),
        status: safe_to_atom(field(record, :status)),
        parent_session_id: field(record, :parent_session_id),
        metadata: atomize_keys(field(record, :metadata) || %{}),
        context: atomize_keys(field(record, :context) || %{}),
        tags: field(record, :tags) || [],
        created_at: field(record, :created_at),
        updated_at: field(record, :updated_at),
        deleted_at: field(record, :deleted_at)
      }
    end

    @spec session_to_attrs(Session.t()) :: map()
    def session_to_attrs(%Session{} = session) do
      %{
        id: session.id,
        agent_id: session.agent_id,
        status: Atom.to_string(session.status),
        parent_session_id: session.parent_session_id,
        metadata: stringify_keys(session.metadata || %{}),
        context: stringify_keys(session.context || %{}),
        tags: session.tags || [],
        created_at: session.created_at,
        updated_at: session.updated_at,
        deleted_at: session.deleted_at
      }
    end

    @spec record_to_run(map() | struct()) :: Run.t()
    def record_to_run(record) do
      %Run{
        id: field(record, :id),
        session_id: field(record, :session_id),
        status: safe_to_atom(field(record, :status)),
        input: atomize_keys_nullable(field(record, :input)),
        output: atomize_keys_nullable(field(record, :output)),
        error: atomize_keys_nullable(field(record, :error)),
        metadata: atomize_keys(field(record, :metadata) || %{}),
        turn_count: field(record, :turn_count) || 0,
        token_usage: atomize_keys(field(record, :token_usage) || %{}),
        started_at: field(record, :started_at),
        ended_at: field(record, :ended_at),
        provider: field(record, :provider),
        provider_metadata: atomize_keys(field(record, :provider_metadata) || %{})
      }
    end

    @spec run_to_attrs(Run.t()) :: map()
    def run_to_attrs(%Run{} = run) do
      %{
        id: run.id,
        session_id: run.session_id,
        status: Atom.to_string(run.status),
        input: stringify_keys(run.input),
        output: stringify_keys(run.output),
        error: stringify_keys(run.error),
        metadata: stringify_keys(run.metadata || %{}),
        turn_count: run.turn_count || 0,
        token_usage: stringify_keys(run.token_usage || %{}),
        started_at: run.started_at,
        ended_at: run.ended_at,
        provider: run.provider,
        provider_metadata: stringify_keys(run.provider_metadata || %{})
      }
    end

    @spec record_to_event(map() | struct()) :: Event.t()
    def record_to_event(record) do
      %Event{
        id: field(record, :id),
        type: safe_to_atom(field(record, :type)),
        timestamp: field(record, :timestamp),
        session_id: field(record, :session_id),
        run_id: field(record, :run_id),
        sequence_number: field(record, :sequence_number),
        data: atomize_keys(field(record, :data) || %{}),
        metadata: atomize_keys(field(record, :metadata) || %{}),
        schema_version: field(record, :schema_version) || 1,
        provider: field(record, :provider),
        correlation_id: field(record, :correlation_id)
      }
    end

    @spec event_to_attrs(Event.t()) :: map()
    def event_to_attrs(%Event{} = event) do
      %{
        id: event.id,
        type: Atom.to_string(event.type),
        timestamp: event.timestamp,
        session_id: event.session_id,
        run_id: event.run_id,
        sequence_number: event.sequence_number,
        data: stringify_keys(event.data || %{}),
        metadata: stringify_keys(event.metadata || %{}),
        schema_version: event.schema_version || 1,
        provider: event.provider,
        correlation_id: event.correlation_id
      }
    end

    @spec event_to_attrs_with_sequence(Event.t(), non_neg_integer()) :: map()
    def event_to_attrs_with_sequence(%Event{} = event, sequence_number) do
      event
      |> event_to_attrs()
      |> Map.put(:sequence_number, sequence_number)
    end

    defp field(record, key) when is_map(record), do: Map.get(record, key)

    defp safe_to_atom(nil), do: nil
    defp safe_to_atom(value) when is_atom(value), do: value
    defp safe_to_atom(value) when is_binary(value), do: String.to_existing_atom(value)

    defp stringify_keys(value), do: Serialization.stringify_keys(value)

    defp atomize_keys(nil), do: %{}
    defp atomize_keys(value), do: Serialization.atomize_keys(value)

    defp atomize_keys_nullable(nil), do: nil
    defp atomize_keys_nullable(map), do: Serialization.atomize_keys(map)
  end
else
  defmodule AgentSessionManager.Ash.Converters do
    @moduledoc false
  end
end
