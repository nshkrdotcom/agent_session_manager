defmodule ASM.Event do
  @moduledoc """
  Run-scoped envelope around core runtime events.
  """

  import Bitwise

  alias ASM.{Content, Control, Message}
  alias CliSubprocessCore.Event, as: CoreEvent
  alias CliSubprocessCore.Payload

  @local_kinds [:run_completed]
  @core_kinds CoreEvent.kinds()
  @kinds @core_kinds ++ @local_kinds

  @enforce_keys [:id, :kind, :run_id, :session_id, :timestamp]
  defstruct [
    :id,
    :run_id,
    :session_id,
    :provider,
    :kind,
    :payload,
    :core_event,
    :sequence,
    :provider_session_id,
    :correlation_id,
    :causation_id,
    :timestamp,
    metadata: %{}
  ]

  @type kind :: CoreEvent.kind() | :run_completed
  @type payload ::
          CoreEvent.payload()
          | Control.RunLifecycle.t()
          | map()
          | nil

  @type t :: %__MODULE__{
          id: String.t(),
          run_id: String.t(),
          session_id: String.t(),
          provider: atom() | nil,
          kind: kind(),
          payload: payload(),
          core_event: CoreEvent.t() | nil,
          sequence: non_neg_integer() | nil,
          provider_session_id: String.t() | nil,
          correlation_id: String.t() | nil,
          causation_id: String.t() | nil,
          timestamp: DateTime.t(),
          metadata: map()
        }

  @crockford ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @ulid_chars 26
  @max_timestamp 281_474_976_710_655
  @normalized_error_kinds %{
    "approval_denied" => :approval_denied,
    "auth_error" => :auth_error,
    "buffer_overflow" => :buffer_overflow,
    "cli_not_found" => :cli_not_found,
    "config_invalid" => :config_invalid,
    "connection_failed" => :connection_failed,
    "json_decode_error" => :json_decode_error,
    "parse_error" => :parse_error,
    "rate_limit" => :rate_limit,
    "timeout" => :timeout,
    "tool_failed" => :tool_failed,
    "transport_busy" => :transport_busy,
    "transport_error" => :transport_error,
    "unknown" => :unknown,
    "user_cancelled" => :user_cancelled
  }

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @spec new(kind(), payload(), keyword() | map()) :: t()
  def new(kind, payload, attrs \\ []) when is_list(attrs) or is_map(attrs) do
    attrs = Enum.into(attrs, %{})

    %__MODULE__{
      id: Map.get(attrs, :id, generate_id()),
      run_id: Map.fetch!(attrs, :run_id),
      session_id: Map.fetch!(attrs, :session_id),
      provider: Map.get(attrs, :provider),
      kind: kind,
      payload: payload,
      core_event: Map.get(attrs, :core_event),
      sequence: Map.get(attrs, :sequence),
      provider_session_id: Map.get(attrs, :provider_session_id),
      correlation_id: Map.get(attrs, :correlation_id),
      causation_id: Map.get(attrs, :causation_id),
      timestamp: Map.get(attrs, :timestamp, DateTime.utc_now()),
      metadata: normalize_metadata(Map.get(attrs, :metadata, %{}))
    }
  end

  @spec wrap_core(map(), CoreEvent.t()) :: t()
  def wrap_core(run_scope, %CoreEvent{} = core_event) when is_map(run_scope) do
    new(core_event.kind, core_event.payload,
      run_id: Map.fetch!(run_scope, :run_id),
      session_id: Map.fetch!(run_scope, :session_id),
      provider: Map.get(run_scope, :provider, core_event.provider),
      core_event: core_event,
      sequence: core_event.sequence,
      provider_session_id: core_event.provider_session_id,
      timestamp: core_event.timestamp,
      metadata:
        Map.merge(Map.get(run_scope, :metadata, %{}), normalize_metadata(core_event.metadata))
    )
  end

  @spec core?(t()) :: boolean()
  def core?(%__MODULE__{core_event: %CoreEvent{}}), do: true
  def core?(%__MODULE__{}), do: false

  @spec legacy_payload(t()) :: term()
  def legacy_payload(%__MODULE__{
        kind: :assistant_delta,
        payload: %Payload.AssistantDelta{} = payload
      }) do
    %Message.Partial{content_type: :text, delta: payload.content}
  end

  def legacy_payload(%__MODULE__{
        kind: :assistant_message,
        payload: %Payload.AssistantMessage{} = payload
      }) do
    %Message.Assistant{
      content: legacy_content(payload.content),
      model: payload.model,
      metadata: payload.metadata
    }
  end

  def legacy_payload(%__MODULE__{kind: :user_message, payload: %Payload.UserMessage{} = payload}) do
    %Message.User{content: legacy_content(payload.content)}
  end

  def legacy_payload(%__MODULE__{kind: :thinking, payload: %Payload.Thinking{} = payload}) do
    %Message.Thinking{thinking: payload.content, signature: payload.signature}
  end

  def legacy_payload(%__MODULE__{kind: :tool_use, payload: %Payload.ToolUse{} = payload}) do
    %Message.ToolUse{
      tool_name: payload.tool_name || "",
      tool_id: payload.tool_call_id || "",
      input: normalize_map(payload.input)
    }
  end

  def legacy_payload(%__MODULE__{kind: :tool_result, payload: %Payload.ToolResult{} = payload}) do
    %Message.ToolResult{
      tool_id: payload.tool_call_id || "",
      content: payload.content,
      is_error: payload.is_error
    }
  end

  def legacy_payload(%__MODULE__{
        kind: :approval_requested,
        payload: %Payload.ApprovalRequested{} = payload
      }) do
    %Control.ApprovalRequest{
      approval_id: payload.approval_id || "",
      tool_name: payload.subject || "",
      tool_input: approval_tool_input(payload.details)
    }
  end

  def legacy_payload(%__MODULE__{
        kind: :approval_resolved,
        payload: %Payload.ApprovalResolved{} = payload
      }) do
    %Control.ApprovalResolution{
      approval_id: payload.approval_id || "",
      decision: normalize_decision(payload.decision),
      reason: payload.reason
    }
  end

  def legacy_payload(%__MODULE__{kind: :cost_update, payload: %Payload.CostUpdate{} = payload}) do
    %Control.CostUpdate{
      input_tokens: payload.input_tokens,
      output_tokens: payload.output_tokens,
      cost_usd: payload.cost_usd
    }
  end

  def legacy_payload(%__MODULE__{kind: :result, payload: %Payload.Result{} = payload}) do
    output = normalize_map(payload.output)
    usage = normalize_map(Map.get(output, :usage) || Map.get(output, "usage") || %{})

    %Message.Result{
      stop_reason: payload.stop_reason,
      usage: %{
        input_tokens: Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") || 0,
        output_tokens: Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0
      },
      duration_ms: Map.get(output, :duration_ms) || Map.get(output, "duration_ms"),
      metadata: payload.metadata
    }
  end

  def legacy_payload(%__MODULE__{kind: :error, payload: %Payload.Error{} = payload}) do
    %Message.Error{
      severity: normalize_legacy_severity(payload.severity),
      message: payload.message,
      kind: normalize_error_kind(payload.code)
    }
  end

  def legacy_payload(%__MODULE__{
        kind: :run_completed,
        payload: %Control.RunLifecycle{} = payload
      }),
      do: payload

  def legacy_payload(%__MODULE__{kind: :run_completed, payload: %{} = payload}) do
    %Control.RunLifecycle{
      status: normalize_run_status(payload[:status] || payload["status"]),
      summary: payload
    }
  end

  def legacy_payload(%__MODULE__{payload: payload}), do: payload

  @spec text_delta(t()) :: String.t() | nil
  def text_delta(%__MODULE__{
        kind: :assistant_delta,
        payload: %Payload.AssistantDelta{content: content}
      })
      when is_binary(content),
      do: content

  def text_delta(%__MODULE__{}), do: nil

  @spec assistant_text(t()) :: String.t() | nil
  def assistant_text(%__MODULE__{kind: :assistant_delta} = event), do: text_delta(event)

  def assistant_text(%__MODULE__{
        kind: :assistant_message,
        payload: %Payload.AssistantMessage{content: content}
      }) do
    content
    |> legacy_content()
    |> Enum.flat_map(fn
      %Content.Text{text: text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join()
  end

  def assistant_text(%__MODULE__{}), do: nil

  @spec result_usage(t()) :: map() | nil
  def result_usage(%__MODULE__{kind: :result} = event) do
    case legacy_payload(event) do
      %Message.Result{usage: usage} -> usage
      _ -> nil
    end
  end

  def result_usage(_event), do: nil

  @spec generate_id() :: String.t()
  def generate_id do
    generate_id_at(System.system_time(:millisecond))
  end

  @spec generate_id_at(non_neg_integer()) :: String.t()
  def generate_id_at(timestamp_ms) when is_integer(timestamp_ms) and timestamp_ms >= 0 do
    if timestamp_ms > @max_timestamp do
      raise ArgumentError, "timestamp out of ULID range: #{timestamp_ms}"
    end

    random = :crypto.strong_rand_bytes(10)
    random_int = :binary.decode_unsigned(random)
    ulid_int = (timestamp_ms <<< 80) + random_int

    encode_crockford(ulid_int, @ulid_chars)
  end

  def generate_id_at(other) do
    raise ArgumentError, "timestamp must be a non-negative integer, got: #{inspect(other)}"
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp approval_tool_input(details) when is_map(details) do
    Map.get(details, "tool_input") || Map.get(details, :tool_input) || %{}
  end

  defp approval_tool_input(_details), do: %{}

  defp normalize_decision(:allow), do: :allow
  defp normalize_decision("allow"), do: :allow
  defp normalize_decision("approved"), do: :allow
  defp normalize_decision(true), do: :allow
  defp normalize_decision(_other), do: :deny

  defp normalize_error_kind(nil), do: :unknown
  defp normalize_error_kind(kind) when is_atom(kind), do: kind

  defp normalize_error_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> lookup_error_kind()
  end

  defp normalize_error_kind(_kind), do: :unknown

  defp lookup_error_kind(""), do: :unknown
  defp lookup_error_kind(kind), do: Map.get(@normalized_error_kinds, kind, :unknown)

  defp normalize_legacy_severity(:info), do: :warning

  defp normalize_legacy_severity(severity) when severity in [:warning, :error, :fatal],
    do: severity

  defp normalize_legacy_severity(_severity), do: :error

  defp normalize_run_status(:failed), do: :failed
  defp normalize_run_status("failed"), do: :failed
  defp normalize_run_status(_status), do: :completed

  defp legacy_content(content) when is_list(content) do
    Enum.map(content, &legacy_content_block/1)
  end

  defp legacy_content(_content), do: []

  defp legacy_content_block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: %Content.Text{text: text}

  defp legacy_content_block(%{type: "text", text: text}) when is_binary(text),
    do: %Content.Text{text: text}

  defp legacy_content_block(%{"type" => "thinking", "thinking" => thinking} = block)
       when is_binary(thinking),
       do: %Content.Thinking{thinking: thinking, signature: Map.get(block, "signature")}

  defp legacy_content_block(%{type: "thinking", thinking: thinking} = block)
       when is_binary(thinking),
       do: %Content.Thinking{thinking: thinking, signature: Map.get(block, :signature)}

  defp legacy_content_block(%{"type" => "tool_use"} = block) do
    %Content.ToolUse{
      tool_name: Map.get(block, "name") || "",
      tool_id: Map.get(block, "id") || "",
      input: normalize_map(Map.get(block, "input"))
    }
  end

  defp legacy_content_block(%{type: "tool_use"} = block) do
    %Content.ToolUse{
      tool_name: Map.get(block, :name) || "",
      tool_id: Map.get(block, :id) || "",
      input: normalize_map(Map.get(block, :input))
    }
  end

  defp legacy_content_block(%{"type" => "tool_result"} = block) do
    %Content.ToolResult{
      tool_id: Map.get(block, "tool_use_id") || Map.get(block, "id") || "",
      content: Map.get(block, "content"),
      is_error: Map.get(block, "is_error", false)
    }
  end

  defp legacy_content_block(%{type: "tool_result"} = block) do
    %Content.ToolResult{
      tool_id: Map.get(block, :tool_use_id) || Map.get(block, :id) || "",
      content: Map.get(block, :content),
      is_error: Map.get(block, :is_error, false)
    }
  end

  defp legacy_content_block(text) when is_binary(text), do: %Content.Text{text: text}
  defp legacy_content_block(other), do: %Content.Text{text: inspect(other)}

  defp encode_crockford(value, width) do
    digits = do_encode(value, [])

    digits
    |> left_pad(width, ?0)
    |> to_string()
  end

  defp do_encode(0, []), do: [?0]
  defp do_encode(0, acc), do: acc

  defp do_encode(value, acc) do
    rem_index = rem(value, 32)
    next = div(value, 32)
    char = Enum.at(@crockford, rem_index)
    do_encode(next, [char | acc])
  end

  defp left_pad(chars, width, pad_char) do
    missing = max(width - length(chars), 0)
    List.duplicate(pad_char, missing) ++ chars
  end
end
