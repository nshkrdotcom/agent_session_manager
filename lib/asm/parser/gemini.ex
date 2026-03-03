defmodule ASM.Parser.Gemini do
  @moduledoc """
  Gemini parser that normalizes raw maps to ASM payload structs.
  """

  alias ASM.{Content, Control, Error, Message, Parser}

  @behaviour Parser

  @impl true
  @spec parse(map()) ::
          {:ok, {ASM.Event.kind(), ASM.Message.t() | ASM.Control.t()}} | {:error, Error.t()}
  def parse(raw) when is_map(raw) do
    type = event_type(raw)
    {:ok, parse_typed(type, raw)}
  rescue
    error ->
      {:error,
       Error.new(:parse_error, :parser, "Gemini parser failure: #{Exception.message(error)}",
         cause: error
       )}
  end

  def parse(other) do
    {:error,
     Error.new(:parse_error, :parser, "Gemini parser expected map, got: #{inspect(other)}")}
  end

  defp parse_typed("init", raw), do: {:system, %Message.System{init_data: normalize_map(raw)}}
  defp parse_typed("tool_use", raw), do: {:tool_use, tool_use_message(raw)}
  defp parse_typed("tool_result", raw), do: {:tool_result, tool_result_message(raw)}
  defp parse_typed("error", raw), do: {:error, error_message(raw)}
  defp parse_typed("result", raw), do: {:result, result_message(raw)}
  defp parse_typed("run_started", raw), do: {:run_started, run_lifecycle(raw, :started)}
  defp parse_typed("run_completed", raw), do: {:run_completed, run_lifecycle(raw, :completed)}

  defp parse_typed("message", raw) do
    role = fetch_any(raw, [:role, "role"])
    content = fetch_any(raw, [:content, "content"]) || ""
    delta = truthy?(fetch_any(raw, [:delta, "delta"]))

    case {role, delta} do
      {"assistant", true} ->
        {:assistant_delta, %Message.Partial{content_type: :text, delta: to_string(content)}}

      {"assistant", _} ->
        {:assistant_message,
         %Message.Assistant{
           content: [%Content.Text{text: to_string(content)}],
           model: fetch_any(raw, [:model, "model"]),
           metadata: normalize_map(raw)
         }}

      {"user", _} ->
        {:user_message, %Message.User{content: [%Content.Text{text: to_string(content)}]}}

      _ ->
        {:raw, %Message.Raw{provider: :gemini, type: "message", data: normalize_map(raw)}}
    end
  end

  defp parse_typed(type, raw) do
    {:raw, %Message.Raw{provider: :gemini, type: type, data: normalize_map(raw)}}
  end

  defp event_type(raw) do
    raw
    |> fetch_any([:type, "type", :event, "event"])
    |> case do
      nil -> "unknown"
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      value -> to_string(value)
    end
  end

  defp tool_use_message(raw) do
    %Message.ToolUse{
      tool_name: fetch_any(raw, [:tool_name, "tool_name", :name, "name"]) || "unknown_tool",
      tool_id: fetch_any(raw, [:tool_id, "tool_id", :id, "id"]) || "unknown_id",
      input: fetch_any(raw, [:input, "input"]) || %{}
    }
  end

  defp tool_result_message(raw) do
    %Message.ToolResult{
      tool_id: fetch_any(raw, [:tool_id, "tool_id", :id, "id"]) || "unknown_id",
      content: fetch_any(raw, [:content, "content", :output, "output"]),
      is_error: truthy?(fetch_any(raw, [:is_error, "is_error", :error, "error"]))
    }
  end

  defp result_message(raw) do
    stats = fetch_any(raw, [:stats, "stats"]) || %{}

    %Message.Result{
      stop_reason: fetch_any(raw, [:status, "status", :stop_reason, "stop_reason"]) || :unknown,
      usage: %{
        input_tokens: fetch_any(stats, [:input_tokens, "input_tokens"]) || 0,
        output_tokens: fetch_any(stats, [:output_tokens, "output_tokens"]) || 0
      },
      metadata: normalize_map(raw)
    }
  end

  defp error_message(raw) do
    %Message.Error{
      severity: normalize_severity(fetch_any(raw, [:severity, "severity"])),
      message: fetch_any(raw, [:message, "message"]) || "Gemini parser error",
      kind: normalize_kind(fetch_any(raw, [:kind, "kind"]))
    }
  end

  defp run_lifecycle(raw, status) do
    %Control.RunLifecycle{
      status: status,
      summary: normalize_map(raw)
    }
  end

  defp fetch_any(raw, keys) do
    Enum.find_value(keys, fn key -> Map.get(raw, key) end)
  end

  defp normalize_map(raw) do
    Map.new(raw, fn {k, v} -> {normalize_key(k), v} end)
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(other), do: other

  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_), do: false

  defp normalize_severity(value) when value in [:fatal, "fatal"], do: :fatal
  defp normalize_severity(value) when value in [:warning, "warning", "warn"], do: :warning
  defp normalize_severity(_), do: :error

  defp normalize_kind(nil), do: :unknown
  defp normalize_kind(kind) when is_atom(kind), do: kind

  defp normalize_kind(kind) when is_binary(kind) do
    case String.downcase(kind) do
      "user_cancelled" -> :user_cancelled
      "parse_error" -> :parse_error
      "timeout" -> :timeout
      "tool_failed" -> :tool_failed
      "approval_denied" -> :approval_denied
      "rate_limit" -> :rate_limit
      _ -> :unknown
    end
  end

  defp normalize_kind(_), do: :unknown
end
