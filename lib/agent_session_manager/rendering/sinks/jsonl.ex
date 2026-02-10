defmodule AgentSessionManager.Rendering.Sinks.JSONLSink do
  @moduledoc """
  A sink that writes events as JSON Lines (one JSON object per line).

  Ignores rendered text (`write/2`) and instead serializes the raw event
  in `write_event/3`. Supports two modes:

  - `:full` — Complete event data with ISO 8601 timestamp (default)
  - `:compact` — Abbreviated fields with millisecond epoch timestamp

  ## Options

    * `:path` — File path to write to. Required.
    * `:mode` — `:full` or `:compact`. Default `:full`.

  ## Full Mode Format

      {"ts":"2026-02-09T12:00:00Z","type":"run_started","data":{"model":"..."}}

  ## Compact Mode Format

      {"t":1707464400123,"e":{"t":"rs","m":"sonnet"}}
  """

  @behaviour AgentSessionManager.Rendering.Sink

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} ->
        mode = Keyword.get(opts, :mode, :full)

        case File.open(path, [:write, :utf8]) do
          {:ok, io} -> {:ok, %{path: path, io: io, mode: mode}}
          {:error, reason} -> {:error, "Failed to open #{path}: #{inspect(reason)}"}
        end

      :error ->
        {:error, "path option is required"}
    end
  end

  @impl true
  def write(_iodata, state), do: {:ok, state}

  @impl true
  def write_event(event, _iodata, state) do
    entry =
      case state.mode do
        :compact -> compact_entry(event)
        _ -> full_entry(event)
      end

    IO.binwrite(state.io, Jason.encode!(entry) <> "\n")
    {:ok, state}
  end

  @impl true
  def flush(state) do
    :file.sync(state.io)
    {:ok, state}
  end

  @impl true
  def close(state) do
    File.close(state.io)
    :ok
  end

  # -- Full mode --

  defp full_entry(event) do
    %{
      "ts" => format_timestamp(event[:timestamp]),
      "type" => to_string(event.type),
      "data" => stringify_data(event[:data] || %{}),
      "session_id" => event[:session_id],
      "run_id" => event[:run_id]
    }
    |> drop_nil_values()
  end

  # -- Compact mode --

  @type_abbrev %{
    run_started: "rs",
    message_streamed: "ms",
    tool_call_started: "ts",
    tool_call_completed: "tc",
    token_usage_updated: "tu",
    message_received: "mr",
    run_completed: "rc",
    run_failed: "rf",
    run_cancelled: "rx",
    error_occurred: "er"
  }

  defp compact_entry(event) do
    %{
      "t" => System.system_time(:millisecond),
      "e" => compact_event(event)
    }
  end

  defp compact_event(event) do
    type_abbrev = Map.get(@type_abbrev, event.type, to_string(event.type))
    data = event[:data] || %{}
    base = %{"t" => type_abbrev}
    Map.merge(base, compact_event_fields(event.type, data))
  end

  defp compact_event_fields(:run_started, data),
    do: drop_nil_values(%{"m" => short_model(data[:model])})

  defp compact_event_fields(:message_streamed, data) do
    text = data[:delta] || data[:content] || ""
    %{"l" => byte_size(text)}
  end

  defp compact_event_fields(:tool_call_started, data),
    do: drop_nil_values(%{"n" => data[:tool_name]})

  defp compact_event_fields(:tool_call_completed, data),
    do: drop_nil_values(%{"n" => data[:tool_name], "l" => safe_length(data[:tool_output])})

  defp compact_event_fields(:token_usage_updated, data),
    do: %{"i" => data[:input_tokens], "o" => data[:output_tokens]}

  defp compact_event_fields(:run_completed, data),
    do: drop_nil_values(%{"sr" => short_reason(data[:stop_reason])})

  defp compact_event_fields(type, data) when type in [:run_failed, :error_occurred],
    do: drop_nil_values(%{"x" => truncate(data[:error_message], 120)})

  defp compact_event_fields(_type, _data), do: %{}

  # -- Helpers --

  defp format_timestamp(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(other), do: inspect(other)

  defp stringify_data(data) when is_map(data) do
    Map.new(data, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_data(other), do: other

  defp stringify_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp stringify_value(v) when is_atom(v) and not is_nil(v) and not is_boolean(v),
    do: Atom.to_string(v)

  defp stringify_value(v) when is_map(v), do: stringify_data(v)
  defp stringify_value(v), do: v

  defp short_model(nil), do: nil

  defp short_model(model) when is_binary(model) do
    model
    |> String.replace_prefix("claude-", "")
    |> String.replace_prefix("anthropic.", "")
    |> String.split("-", trim: true)
    |> Enum.take(3)
    |> Enum.join("-")
  end

  defp short_model(model), do: to_string(model)

  defp short_reason(nil), do: nil

  defp short_reason(reason) when is_binary(reason) do
    case String.downcase(reason) do
      "tool_use" -> "tool"
      "end_turn" -> "end"
      other -> other
    end
  end

  defp short_reason(reason), do: to_string(reason)

  defp safe_length(nil), do: nil
  defp safe_length(text) when is_binary(text), do: byte_size(text)
  defp safe_length(other), do: byte_size(inspect(other))

  defp truncate(nil, _limit), do: nil

  defp truncate(text, limit) when is_binary(text) do
    if String.length(text) > limit do
      String.slice(text, 0, limit) <> "..."
    else
      text
    end
  end

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end
end
