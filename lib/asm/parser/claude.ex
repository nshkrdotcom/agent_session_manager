defmodule ASM.Parser.Claude do
  @moduledoc """
  Claude event parser that normalizes raw maps to ASM payload structs.
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
       Error.new(:parse_error, :parser, "Claude parser failure: #{Exception.message(error)}",
         cause: error
       )}
  end

  def parse(other) do
    {:error,
     Error.new(:parse_error, :parser, "Claude parser expected map, got: #{inspect(other)}")}
  end

  defp parse_typed("assistant", raw), do: {:assistant_message, assistant_message(raw)}
  defp parse_typed("assistant_message", raw), do: {:assistant_message, assistant_message(raw)}
  defp parse_typed("assistant_delta", raw), do: {:assistant_delta, assistant_delta(raw)}
  defp parse_typed("text_delta", raw), do: {:assistant_delta, assistant_delta(raw)}
  defp parse_typed("thinking", raw), do: {:thinking, thinking_message(raw)}
  defp parse_typed("tool_use", raw), do: {:tool_use, tool_use_message(raw)}
  defp parse_typed("tool_result", raw), do: {:tool_result, tool_result_message(raw)}
  defp parse_typed("result", raw), do: {:result, result_message(raw)}
  defp parse_typed("error", raw), do: {:error, error_message(raw)}
  defp parse_typed("system", raw), do: {:system, %Message.System{init_data: raw}}
  defp parse_typed("run_started", raw), do: {:run_started, run_lifecycle(raw, :started)}
  defp parse_typed("run_completed", raw), do: {:run_completed, run_lifecycle(raw, :completed)}
  defp parse_typed("approval_requested", raw), do: {:approval_requested, approval_requested(raw)}
  defp parse_typed("approval_resolved", raw), do: {:approval_resolved, approval_resolved(raw)}
  defp parse_typed("cost_update", raw), do: {:cost_update, cost_update(raw)}

  defp parse_typed(type, raw) do
    {:raw, %Message.Raw{provider: :claude, type: type, data: normalize_map(raw)}}
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

  defp assistant_message(raw) do
    %Message.Assistant{
      content: extract_content_blocks(raw),
      model: fetch_any(raw, [:model, "model"]),
      metadata: normalize_map(raw)
    }
  end

  defp assistant_delta(raw) do
    %Message.Partial{
      content_type: :text,
      delta: fetch_any(raw, [:delta, "delta", :text, "text"]) || ""
    }
  end

  defp thinking_message(raw) do
    %Message.Thinking{
      thinking: fetch_any(raw, [:thinking, "thinking", :text, "text"]) || "",
      signature: fetch_any(raw, [:signature, "signature"])
    }
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
      content: fetch_any(raw, [:content, "content"]),
      is_error: truthy?(fetch_any(raw, [:is_error, "is_error", :error, "error"]))
    }
  end

  defp result_message(raw) do
    usage_map = fetch_any(raw, [:usage, "usage"]) || %{}

    %Message.Result{
      stop_reason: fetch_any(raw, [:stop_reason, "stop_reason", :reason, "reason"]) || :unknown,
      usage: %{
        input_tokens: fetch_any(usage_map, [:input_tokens, "input_tokens"]) || 0,
        output_tokens: fetch_any(usage_map, [:output_tokens, "output_tokens"]) || 0
      },
      duration_ms: fetch_any(raw, [:duration_ms, "duration_ms"]),
      metadata: normalize_map(raw)
    }
  end

  defp error_message(raw) do
    %Message.Error{
      severity: normalize_severity(fetch_any(raw, [:severity, "severity"])),
      message: fetch_any(raw, [:message, "message"]) || "Claude parser error",
      kind: normalize_kind(fetch_any(raw, [:kind, "kind"]))
    }
  end

  defp run_lifecycle(raw, status) do
    %Control.RunLifecycle{
      status: status,
      summary: normalize_map(raw)
    }
  end

  defp approval_requested(raw) do
    %Control.ApprovalRequest{
      approval_id: fetch_any(raw, [:approval_id, "approval_id"]) || "unknown_approval",
      tool_name: fetch_any(raw, [:tool_name, "tool_name"]) || "unknown_tool",
      tool_input: fetch_any(raw, [:tool_input, "tool_input", :input, "input"]) || %{}
    }
  end

  defp approval_resolved(raw) do
    %Control.ApprovalResolution{
      approval_id: fetch_any(raw, [:approval_id, "approval_id"]) || "unknown_approval",
      decision: normalize_decision(fetch_any(raw, [:decision, "decision"])),
      reason: fetch_any(raw, [:reason, "reason"])
    }
  end

  defp cost_update(raw) do
    %Control.CostUpdate{
      input_tokens: fetch_any(raw, [:input_tokens, "input_tokens"]) || 0,
      output_tokens: fetch_any(raw, [:output_tokens, "output_tokens"]) || 0,
      cost_usd: fetch_any(raw, [:cost_usd, "cost_usd"]) || 0.0
    }
  end

  defp extract_content_blocks(raw) do
    case fetch_any(raw, [:content, "content"]) do
      content when is_list(content) ->
        Enum.map(content, &to_content_block/1)

      text when is_binary(text) ->
        [%Content.Text{text: text}]

      _ ->
        text = fetch_any(raw, [:text, "text"]) || ""
        [%Content.Text{text: text}]
    end
  end

  defp to_content_block(%{"type" => "text", "text" => text}), do: %Content.Text{text: text}
  defp to_content_block(%{type: "text", text: text}), do: %Content.Text{text: text}

  defp to_content_block(%{"type" => "thinking", "thinking" => thinking} = data) do
    %Content.Thinking{thinking: thinking, signature: Map.get(data, "signature")}
  end

  defp to_content_block(%{type: "thinking", thinking: thinking} = data) do
    %Content.Thinking{thinking: thinking, signature: Map.get(data, :signature)}
  end

  defp to_content_block(%{"type" => "tool_use"} = data) do
    %Content.ToolUse{
      tool_name: Map.get(data, "name") || "unknown_tool",
      tool_id: Map.get(data, "id") || "unknown_id",
      input: Map.get(data, "input") || %{}
    }
  end

  defp to_content_block(%{"type" => "tool_result"} = data) do
    %Content.ToolResult{
      tool_id: Map.get(data, "tool_id") || "unknown_id",
      content: Map.get(data, "content"),
      is_error: truthy?(Map.get(data, "is_error"))
    }
  end

  defp to_content_block(other) do
    %Content.Text{text: inspect(other)}
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

  defp normalize_decision(value) when value in [:allow, "allow", "approved", true], do: :allow
  defp normalize_decision(_), do: :deny

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
