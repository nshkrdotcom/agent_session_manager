defmodule ASM.Parser.Amp do
  @moduledoc """
  Amp parser that normalizes event maps to ASM payload structs.
  """

  alias ASM.{Content, Control, Error, Message, Parser}
  alias ASM.Parser.Common

  @behaviour Parser

  @impl true
  @spec parse(map()) ::
          {:ok, {ASM.Event.kind(), ASM.Message.t() | ASM.Control.t()}} | {:error, Error.t()}
  def parse(raw) when is_map(raw) do
    type = Common.event_type(raw)
    {:ok, parse_typed(type, raw)}
  rescue
    error ->
      {:error, Common.parser_failure("Amp", error)}
  end

  def parse(other) do
    {:error, Common.expected_map_error("Amp", other)}
  end

  defp parse_typed("system", raw), do: {:run_started, run_lifecycle(raw, :started)}
  defp parse_typed("run_started", raw), do: {:run_started, run_lifecycle(raw, :started)}

  defp parse_typed("assistant_delta", raw), do: {:assistant_delta, assistant_delta(raw)}
  defp parse_typed("message_streamed", raw), do: {:assistant_delta, assistant_delta(raw)}

  defp parse_typed("assistant_message", raw), do: {:assistant_message, assistant_message(raw)}
  defp parse_typed("message_received", raw), do: {:assistant_message, assistant_message(raw)}

  defp parse_typed("tool_use", raw), do: {:tool_use, tool_use_message(raw)}
  defp parse_typed("tool_call_started", raw), do: {:tool_use, tool_use_message(raw)}

  defp parse_typed("tool_result", raw), do: {:tool_result, tool_result_message(raw)}

  defp parse_typed("tool_call_completed", raw),
    do: {:tool_result, tool_result_message(raw, false)}

  defp parse_typed("tool_call_failed", raw),
    do: {:tool_result, tool_result_message(raw, true)}

  defp parse_typed("token_usage_updated", raw), do: {:cost_update, cost_update(raw)}
  defp parse_typed("cost_update", raw), do: {:cost_update, cost_update(raw)}

  defp parse_typed("run_completed", raw), do: {:result, result_message(raw)}
  defp parse_typed("result", raw), do: {:result, result_message(raw)}

  defp parse_typed("run_cancelled", _raw), do: {:error, cancelled_error()}
  defp parse_typed("run_failed", raw), do: {:error, error_message(raw)}
  defp parse_typed("error_occurred", raw), do: {:error, error_message(raw)}
  defp parse_typed("error", raw), do: {:error, error_message(raw)}

  defp parse_typed("approval_requested", raw), do: {:approval_requested, approval_requested(raw)}
  defp parse_typed("approval_resolved", raw), do: {:approval_resolved, approval_resolved(raw)}

  defp parse_typed("message", raw) do
    role = Common.fetch_any(raw, [:role, "role"])

    case role do
      "assistant" -> {:assistant_message, assistant_message(raw)}
      "user" -> {:user_message, %Message.User{content: extract_content_blocks(raw)}}
      _ -> raw_message("message", raw)
    end
  end

  defp parse_typed(type, raw), do: raw_message(type, raw)

  defp assistant_delta(raw) do
    delta = Common.fetch_any(raw, [:delta, "delta", :text, "text", :content, "content"])

    %Message.Partial{
      content_type: :text,
      delta: delta_to_string(delta)
    }
  end

  defp assistant_message(raw) do
    %Message.Assistant{
      content: extract_content_blocks(raw),
      model: Common.fetch_any(raw, [:model, "model"]),
      metadata: Common.normalize_map(raw)
    }
  end

  defp tool_use_message(raw) do
    %Message.ToolUse{
      tool_name:
        Common.fetch_any(raw, [:tool_name, "tool_name", :name, "name"]) || "unknown_tool",
      tool_id:
        Common.fetch_any(raw, [:tool_call_id, "tool_call_id", :tool_id, "tool_id", :id, "id"]) ||
          "unknown_id",
      input: tool_input(raw)
    }
  end

  defp tool_result_message(raw, force_error \\ nil) do
    is_error =
      case force_error do
        value when is_boolean(value) -> value
        _ -> Common.truthy?(Common.fetch_any(raw, [:is_error, "is_error", :error, "error"]))
      end

    %Message.ToolResult{
      tool_id:
        Common.fetch_any(raw, [:tool_call_id, "tool_call_id", :tool_id, "tool_id", :id, "id"]) ||
          "unknown_id",
      content:
        Common.fetch_any(raw, [
          :tool_output,
          "tool_output",
          :content,
          "content",
          :output,
          "output"
        ]),
      is_error: is_error
    }
  end

  defp result_message(raw) do
    usage_map =
      Common.fetch_any(raw, [:token_usage, "token_usage", :usage, "usage", :stats, "stats"])

    usage_map = if is_map(usage_map), do: usage_map, else: %{}

    %Message.Result{
      stop_reason:
        Common.fetch_any(raw, [:stop_reason, "stop_reason", :status, "status", :reason, "reason"]) ||
          :unknown,
      usage: %{
        input_tokens: Common.int_value(usage_map, [:input_tokens, "input_tokens"]),
        output_tokens: Common.int_value(usage_map, [:output_tokens, "output_tokens"])
      },
      duration_ms: Common.fetch_any(raw, [:duration_ms, "duration_ms"]),
      metadata: Common.normalize_map(raw)
    }
  end

  defp error_message(raw) do
    kind =
      Common.fetch_any(raw, [:error_code, "error_code", :error_kind, "error_kind", :kind, "kind"])
      |> Common.normalize_kind()

    %Message.Error{
      severity: Common.normalize_severity(Common.fetch_any(raw, [:severity, "severity"])),
      message:
        Common.fetch_any(raw, [:error_message, "error_message", :message, "message"]) ||
          "Amp parser error",
      kind: kind
    }
  end

  defp cancelled_error do
    %Message.Error{severity: :warning, message: "Run cancelled", kind: :user_cancelled}
  end

  defp run_lifecycle(raw, status) do
    %Control.RunLifecycle{status: status, summary: Common.normalize_map(raw)}
  end

  defp cost_update(raw) do
    usage_map =
      Common.fetch_any(raw, [:token_usage, "token_usage", :usage, "usage", :stats, "stats"])

    usage_map = if is_map(usage_map), do: usage_map, else: raw

    %Control.CostUpdate{
      input_tokens: Common.int_value(usage_map, [:input_tokens, "input_tokens"]),
      output_tokens: Common.int_value(usage_map, [:output_tokens, "output_tokens"]),
      cost_usd: Common.float_value(raw, [:cost_usd, "cost_usd"], 0.0)
    }
  end

  defp approval_requested(raw) do
    %Control.ApprovalRequest{
      approval_id: Common.fetch_any(raw, [:approval_id, "approval_id"]) || "unknown_approval",
      tool_name:
        Common.fetch_any(raw, [:tool_name, "tool_name", :name, "name"]) || "unknown_tool",
      tool_input: tool_input(raw)
    }
  end

  defp approval_resolved(raw) do
    %Control.ApprovalResolution{
      approval_id: Common.fetch_any(raw, [:approval_id, "approval_id"]) || "unknown_approval",
      decision: normalize_decision(Common.fetch_any(raw, [:decision, "decision"])),
      reason: Common.fetch_any(raw, [:reason, "reason"])
    }
  end

  defp extract_content_blocks(raw) do
    case Common.fetch_any(raw, [:content, "content", :text, "text", :delta, "delta"]) do
      content when is_list(content) -> Enum.map(content, &to_content_block/1)
      content when is_binary(content) -> [%Content.Text{text: content}]
      nil -> [%Content.Text{text: ""}]
      other -> [%Content.Text{text: inspect(other)}]
    end
  end

  defp to_content_block(%{"type" => "text", "text" => text}), do: %Content.Text{text: text}
  defp to_content_block(%{type: "text", text: text}), do: %Content.Text{text: text}

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
      is_error: Common.truthy?(Map.get(data, "is_error"))
    }
  end

  defp to_content_block(other), do: %Content.Text{text: inspect(other)}

  defp delta_to_string(value) when is_binary(value), do: value
  defp delta_to_string(nil), do: ""
  defp delta_to_string(value), do: to_string(value)

  defp tool_input(raw) do
    case Common.fetch_any(raw, [:tool_input, "tool_input", :input, "input"]) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp raw_message(type, raw) do
    {:raw, %Message.Raw{provider: :amp, type: type, data: Common.normalize_map(raw)}}
  end

  defp normalize_decision(value) when value in [:allow, "allow", "approved", true], do: :allow
  defp normalize_decision(_), do: :deny
end
