defmodule AgentSessionManager.Adapters.EctoSessionStore.Converters do
  @moduledoc false

  alias AgentSessionManager.Adapters.EctoSessionStore.Schemas.{
    ArtifactSchema,
    EventSchema,
    RunSchema,
    SessionSchema
  }

  alias AgentSessionManager.Core.{Event, Run, Serialization, Session}

  @spec schema_to_session(struct()) :: Session.t()
  def schema_to_session(%SessionSchema{} = session_schema) do
    %Session{
      id: session_schema.id,
      agent_id: session_schema.agent_id,
      status: safe_to_atom(session_schema.status),
      parent_session_id: session_schema.parent_session_id,
      metadata: atomize_keys(session_schema.metadata || %{}),
      context: atomize_keys(session_schema.context || %{}),
      tags: session_schema.tags || [],
      created_at: session_schema.created_at,
      updated_at: session_schema.updated_at,
      deleted_at: session_schema.deleted_at
    }
  end

  @spec schema_to_run(struct()) :: Run.t()
  def schema_to_run(%RunSchema{} = run_schema) do
    %Run{
      id: run_schema.id,
      session_id: run_schema.session_id,
      status: safe_to_atom(run_schema.status),
      input: atomize_keys_nullable(run_schema.input),
      output: atomize_keys_nullable(run_schema.output),
      error: atomize_keys_nullable(run_schema.error),
      metadata: atomize_keys(run_schema.metadata || %{}),
      turn_count: run_schema.turn_count || 0,
      token_usage: atomize_keys(run_schema.token_usage || %{}),
      started_at: run_schema.started_at,
      ended_at: run_schema.ended_at,
      provider: run_schema.provider,
      provider_metadata: atomize_keys(run_schema.provider_metadata || %{})
    }
  end

  @spec schema_to_event(struct()) :: Event.t()
  def schema_to_event(%EventSchema{} = event_schema) do
    %Event{
      id: event_schema.id,
      type: safe_to_atom(event_schema.type),
      timestamp: event_schema.timestamp,
      session_id: event_schema.session_id,
      run_id: event_schema.run_id,
      sequence_number: event_schema.sequence_number,
      data: atomize_keys(event_schema.data || %{}),
      metadata: atomize_keys(event_schema.metadata || %{}),
      schema_version: event_schema.schema_version || 1,
      provider: event_schema.provider,
      correlation_id: event_schema.correlation_id
    }
  end

  @spec schema_to_artifact_meta(struct()) :: map()
  def schema_to_artifact_meta(%ArtifactSchema{} = artifact_schema) do
    %{
      id: artifact_schema.id,
      session_id: artifact_schema.session_id,
      run_id: artifact_schema.run_id,
      key: artifact_schema.key,
      content_type: artifact_schema.content_type,
      byte_size: artifact_schema.byte_size,
      checksum_sha256: artifact_schema.checksum_sha256,
      storage_backend: artifact_schema.storage_backend,
      storage_ref: artifact_schema.storage_ref,
      metadata: artifact_schema.metadata,
      created_at: artifact_schema.created_at
    }
  end

  defp safe_to_atom(nil), do: nil
  defp safe_to_atom(value) when is_atom(value), do: value
  defp safe_to_atom(value) when is_binary(value), do: String.to_existing_atom(value)

  defp atomize_keys(nil), do: %{}
  defp atomize_keys(value), do: Serialization.atomize_keys(value)

  defp atomize_keys_nullable(nil), do: nil
  defp atomize_keys_nullable(map), do: Serialization.atomize_keys(map)
end
