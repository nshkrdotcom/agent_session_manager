defmodule ASM.Schema.Event do
  @moduledoc """
  Schema-backed parser for ASM runtime event envelopes before projection into
  `%ASM.Event{}`.
  """

  alias ASM.Event
  alias ASM.Schema
  alias CliSubprocessCore.Event, as: CoreEvent
  alias CliSubprocessCore.Schema.Conventions

  @kinds CoreEvent.kinds() ++
           [
             :run_completed,
             :host_tool_requested,
             :host_tool_completed,
             :host_tool_failed,
             :host_tool_denied,
             :session_checkpoint,
             :session_resumed
           ]

  @known_fields [
    :id,
    :kind,
    :run_id,
    :session_id,
    :provider,
    :payload,
    :core_event,
    :sequence,
    :provider_session_id,
    :correlation_id,
    :causation_id,
    :timestamp,
    :metadata
  ]

  @schema Zoi.map(
            %{
              id: Conventions.optional_trimmed_string(),
              kind: Conventions.enum(@kinds),
              run_id: Conventions.trimmed_string() |> Zoi.min(1),
              session_id: Conventions.trimmed_string() |> Zoi.min(1),
              provider: Conventions.optional_any(),
              payload: Conventions.optional_any(),
              core_event: Conventions.optional_any(),
              sequence: Conventions.optional_any(),
              provider_session_id: Conventions.optional_trimmed_string(),
              correlation_id: Conventions.optional_trimmed_string(),
              causation_id: Conventions.optional_trimmed_string(),
              timestamp: Conventions.optional_any(),
              metadata: Conventions.default_map(%{})
            },
            unrecognized_keys: :preserve
          )

  @spec parse(keyword() | map()) ::
          {:ok, map()} | {:error, {:invalid_asm_event, CliSubprocessCore.Schema.error_detail()}}
  def parse(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = attrs |> Enum.into(%{}) |> normalize_keys()

    with {:ok, parsed} <- Schema.parse(@schema, attrs, :invalid_asm_event),
         {known, extra} = Schema.split_extra(parsed, @known_fields),
         {:ok, provider} <- normalize_provider(Map.get(known, :provider)),
         {:ok, sequence} <- normalize_sequence(Map.get(known, :sequence)),
         {:ok, timestamp} <- normalize_timestamp(Map.get(known, :timestamp)) do
      {:ok,
       %{
         id: Map.get(known, :id) || Event.generate_id(),
         kind: Map.fetch!(known, :kind),
         run_id: Map.fetch!(known, :run_id),
         session_id: Map.fetch!(known, :session_id),
         provider: provider,
         payload: Map.get(known, :payload),
         core_event: Map.get(known, :core_event),
         sequence: sequence,
         provider_session_id: Map.get(known, :provider_session_id),
         correlation_id: Map.get(known, :correlation_id),
         causation_id: Map.get(known, :causation_id),
         timestamp: timestamp,
         metadata: Map.get(known, :metadata, %{}),
         extra: extra
       }}
    else
      {:error, {:invalid_asm_event, details}} ->
        {:error, {:invalid_asm_event, details}}

      {:error, message} when is_binary(message) ->
        {:error,
         {:invalid_asm_event,
          %{
            message: message,
            errors: %{},
            issues: [%{code: :invalid, message: message, path: []}]
          }}}
    end
  end

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  defp normalize_keys(map) do
    Enum.reduce(map, %{}, fn
      {"id", value}, acc -> Map.put(acc, :id, value)
      {"kind", value}, acc -> Map.put(acc, :kind, value)
      {"run_id", value}, acc -> Map.put(acc, :run_id, value)
      {"session_id", value}, acc -> Map.put(acc, :session_id, value)
      {"provider", value}, acc -> Map.put(acc, :provider, value)
      {"payload", value}, acc -> Map.put(acc, :payload, value)
      {"core_event", value}, acc -> Map.put(acc, :core_event, value)
      {"sequence", value}, acc -> Map.put(acc, :sequence, value)
      {"provider_session_id", value}, acc -> Map.put(acc, :provider_session_id, value)
      {"correlation_id", value}, acc -> Map.put(acc, :correlation_id, value)
      {"causation_id", value}, acc -> Map.put(acc, :causation_id, value)
      {"timestamp", value}, acc -> Map.put(acc, :timestamp, value)
      {"metadata", value}, acc -> Map.put(acc, :metadata, value)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp normalize_provider(nil), do: {:ok, nil}
  defp normalize_provider(provider) when is_atom(provider), do: {:ok, provider}

  defp normalize_provider(provider) when is_binary(provider) do
    normalized = String.trim(provider)

    try do
      {:ok, String.to_existing_atom(normalized)}
    rescue
      ArgumentError -> {:error, "provider must be an existing atom or nil"}
    end
  end

  defp normalize_provider(_provider), do: {:error, "provider must be an atom, string, or nil"}

  defp normalize_sequence(nil), do: {:ok, nil}
  defp normalize_sequence(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp normalize_sequence(_value), do: {:error, "sequence must be a non-negative integer or nil"}

  defp normalize_timestamp(nil), do: {:ok, DateTime.utc_now()}
  defp normalize_timestamp(%DateTime{} = timestamp), do: {:ok, timestamp}

  defp normalize_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      _ -> {:error, "timestamp must be a DateTime or ISO8601 string"}
    end
  end

  defp normalize_timestamp(_timestamp),
    do: {:error, "timestamp must be a DateTime or ISO8601 string"}
end
