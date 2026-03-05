defmodule ASM.Migration.MainCompat do
  @moduledoc """
  Compatibility helpers for migrating `main` SessionManager input/event shapes
  to the rebuild `ASM` runtime.

  This module is intentionally explicit about unsupported migration paths:

  - Amp and Shell adapter migration is blocked in this helper.
  - `main` workflow options that require extension/domain parity are rejected
    with actionable `%ASM.Error{}` messages.
  """

  alias ASM.{Content, Control, Error, Event, Message, Options, Provider}

  @type provider_hint :: atom() | String.t()
  @type main_input :: String.t() | map()

  @type legacy_event :: %{
          required(:type) => atom(),
          required(:timestamp) => DateTime.t(),
          required(:session_id) => String.t(),
          required(:run_id) => String.t(),
          required(:data) => map(),
          required(:provider) => atom()
        }

  @type query_spec :: %{
          provider: :claude | :codex | :gemini,
          prompt: String.t(),
          session_opts: keyword(),
          query_opts: keyword()
        }

  @supported_provider_names %{
    "claude" => :claude,
    "codex" => :codex,
    "codex_exec" => :codex,
    "gemini" => :gemini,
    "amp" => :amp,
    "shell" => :shell
  }

  @adapter_provider_names %{
    "Elixir.AgentSessionManager.Adapters.ClaudeAdapter" => :claude,
    "Elixir.AgentSessionManager.Adapters.CodexAdapter" => :codex,
    "Elixir.AgentSessionManager.Adapters.GeminiAdapter" => :gemini,
    "Elixir.AgentSessionManager.Adapters.AmpAdapter" => :amp,
    "Elixir.AgentSessionManager.Adapters.ShellAdapter" => :shell
  }

  @unsupported_option_messages %{
    continuation:
      "`continuation` is unsupported in this compatibility helper. Use transcript replay/resume patterns directly with ASM sessions.",
    continuation_opts:
      "`continuation_opts` is unsupported in this compatibility helper. Use `ASM.History` and explicit replay logic instead.",
    required_capabilities:
      "`required_capabilities` is unsupported in this compatibility helper. Capability negotiation from main is not mapped to rebuild core.",
    optional_capabilities:
      "`optional_capabilities` is unsupported in this compatibility helper. Capability negotiation from main is not mapped to rebuild core.",
    policy:
      "`policy` is unsupported in this compatibility helper. Migrate policy behavior through `ASM.Extensions.Policy`.",
    policies:
      "`policies` is unsupported in this compatibility helper. Migrate policy behavior through `ASM.Extensions.Policy`.",
    workspace:
      "`workspace` is unsupported in this compatibility helper. Migrate workspace behavior through `ASM.Extensions.Workspace`."
  }

  @session_passthrough_keys [:session_id, :agent_id, :metadata, :context, :tags]

  @non_query_keys [
                    :session_id,
                    :agent_id,
                    :metadata,
                    :context,
                    :tags,
                    :event_callback,
                    :adapter_opts
                  ] ++ Map.keys(@unsupported_option_messages)

  @option_aliases %{
    working_directory: :cwd,
    timeout: :transport_timeout_ms,
    execute_timeout_ms: :transport_timeout_ms,
    thinking: :include_thinking
  }

  @permission_aliases %{
    default: :default,
    auto: :auto,
    full_auto: :auto,
    accept_edits: :auto,
    delegate: :auto,
    dont_ask: :auto,
    auto_edit: :auto,
    bypass: :bypass,
    dangerously_skip_permissions: :bypass,
    bypass_permissions: :bypass,
    yolo: :bypass,
    dangerously_allow_all: :bypass,
    plan: :plan
  }

  @string_option_keys %{
    "working_directory" => :working_directory,
    "timeout" => :timeout,
    "execute_timeout_ms" => :execute_timeout_ms,
    "thinking" => :thinking,
    "permission_mode" => :permission_mode,
    "reasoning_effort" => :reasoning_effort,
    "command_timeout_ms" => :command_timeout_ms,
    "success_exit_codes" => :success_exit_codes,
    "allowed_commands" => :allowed_commands,
    "denied_commands" => :denied_commands,
    "model" => :model,
    "mode" => :mode,
    "include_thinking" => :include_thinking,
    "tools" => :tools,
    "sandbox" => :sandbox,
    "extensions" => :extensions,
    "cwd" => :cwd,
    "cli_path" => :cli_path,
    "env" => :env,
    "args" => :args
  }

  @string_permission_modes %{
    "default" => :default,
    "auto" => :auto,
    "full_auto" => :full_auto,
    "accept_edits" => :accept_edits,
    "delegate" => :delegate,
    "dont_ask" => :dont_ask,
    "auto_edit" => :auto_edit,
    "bypass" => :bypass,
    "dangerously_skip_permissions" => :dangerously_skip_permissions,
    "bypass_permissions" => :bypass_permissions,
    "yolo" => :yolo,
    "dangerously_allow_all" => :dangerously_allow_all,
    "plan" => :plan
  }

  @legacy_provider_names %{
    "claude" => :claude,
    "codex" => :codex,
    "codex_exec" => :codex,
    "gemini" => :gemini,
    "amp" => :amp,
    "shell" => :shell
  }

  @spec resolve_provider(provider_hint()) ::
          {:ok, :claude | :codex | :gemini} | {:error, Error.t()}
  def resolve_provider(provider_hint) do
    case normalize_provider_hint(provider_hint) do
      {:ok, :amp} ->
        {:error,
         config_error(
           "Amp migration is unsupported in this compatibility helper. Keep Amp workloads on main or migrate manually after parity gaps are closed."
         )}

      {:ok, :shell} ->
        {:error,
         config_error(
           "Shell migration is unsupported in this compatibility helper. Keep Shell workloads on main or migrate manually with explicit command policy controls."
         )}

      {:ok, provider} when provider in [:claude, :codex, :gemini] ->
        {:ok, provider}

      _ ->
        {:error,
         config_error(
           "Unable to resolve provider from #{inspect(provider_hint)}. Use claude/codex/gemini or a known main adapter module name."
         )}
    end
  end

  @spec input_to_prompt(main_input()) :: {:ok, String.t()} | {:error, Error.t()}
  def input_to_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      {:error,
       config_error(
         "Unsupported input shape. Expected non-empty prompt string or map with `prompt`/`messages`."
       )}
    else
      {:ok, prompt}
    end
  end

  def input_to_prompt(%{} = input) do
    cond do
      is_binary(Map.get(input, :prompt)) and String.trim(Map.get(input, :prompt)) != "" ->
        {:ok, Map.fetch!(input, :prompt)}

      is_binary(Map.get(input, "prompt")) and String.trim(Map.get(input, "prompt")) != "" ->
        {:ok, Map.fetch!(input, "prompt")}

      is_list(Map.get(input, :messages)) ->
        normalize_messages(Map.get(input, :messages))

      is_list(Map.get(input, "messages")) ->
        normalize_messages(Map.get(input, "messages"))

      true ->
        {:error,
         config_error(
           "Unsupported input shape. Expected non-empty prompt string or map with `prompt`/`messages`."
         )}
    end
  end

  def input_to_prompt(_other) do
    {:error,
     config_error(
       "Unsupported input shape. Expected non-empty prompt string or map with `prompt`/`messages`."
     )}
  end

  @spec build_query(provider_hint(), main_input(), keyword()) ::
          {:ok, query_spec()} | {:error, Error.t()}
  def build_query(provider_hint, input, opts \\ [])

  def build_query(provider_hint, input, opts) when is_list(opts) do
    with {:ok, provider} <- resolve_provider(provider_hint),
         :ok <- ensure_supported_options(opts),
         {:ok, prompt} <- input_to_prompt(input),
         {:ok, query_opts} <- build_query_opts(provider, opts) do
      session_opts = build_session_opts(provider, opts, query_opts)

      {:ok,
       %{
         provider: provider,
         prompt: prompt,
         session_opts: session_opts,
         query_opts: query_opts
       }}
    end
  end

  def build_query(_provider_hint, _input, opts) do
    {:error, config_error("Expected options to be a keyword list, got: #{inspect(opts)}")}
  end

  @spec run_once(provider_hint(), main_input(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run_once(provider_hint, input, opts \\ []) when is_list(opts) do
    with {:ok, spec} <- build_query(provider_hint, input, opts),
         {:ok, session} <- ASM.start_session(spec.session_opts) do
      try do
        callback = Keyword.get(opts, :event_callback)

        {events, legacy_events} =
          session
          |> ASM.stream(spec.prompt, spec.query_opts)
          |> Enum.reduce({[], []}, fn event, {events_acc, legacy_acc} ->
            mapped = bridge_event(event)
            maybe_emit_callback(callback, mapped)
            {[event | events_acc], Enum.reverse(mapped) ++ legacy_acc}
          end)
          |> then(fn {events_acc, legacy_acc} ->
            {Enum.reverse(events_acc), Enum.reverse(legacy_acc)}
          end)

        case events do
          [] ->
            {:error, Error.new(:unknown, :runtime, "ASM stream produced no events")}

          _ ->
            result = ASM.Stream.final_result(events)

            case result.error do
              nil ->
                {:ok, legacy_result(result, legacy_events)}

              %Error{} = error ->
                {:error, error}
            end
        end
      rescue
        error in [Error] ->
          {:error, error}

        error ->
          {:error, Error.new(:unknown, :runtime, Exception.message(error), cause: error)}
      after
        _ = ASM.stop_session(session)
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:unknown, :runtime, inspect(reason), cause: reason)}
    end
  end

  @spec run_once(term(), provider_hint(), main_input(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run_once(_store, provider_hint, input, opts) when is_list(opts) do
    run_once(provider_hint, input, opts)
  end

  @spec bridge_event(Event.t()) :: [legacy_event()]
  def bridge_event(
        %Event{kind: :assistant_delta, payload: %Message.Partial{delta: delta}} = event
      )
      when is_binary(delta) do
    [legacy_event(event, :message_streamed, %{content: delta, delta: delta})]
  end

  def bridge_event(
        %Event{kind: :assistant_message, payload: %Message.Assistant{} = payload} = event
      ) do
    text = extract_text(payload.content)
    [legacy_event(event, :message_received, %{content: text, role: "assistant"})]
  end

  def bridge_event(%Event{kind: :user_message, payload: %Message.User{} = payload} = event) do
    text = extract_text(payload.content)
    [legacy_event(event, :message_sent, %{content: text, role: "user"})]
  end

  def bridge_event(%Event{kind: :tool_use, payload: %Message.ToolUse{} = payload} = event) do
    [
      legacy_event(event, :tool_call_started, %{
        tool_call_id: payload.tool_id,
        tool_name: payload.tool_name,
        tool_input: payload.input
      })
    ]
  end

  def bridge_event(%Event{kind: :tool_result, payload: %Message.ToolResult{} = payload} = event) do
    type = if payload.is_error, do: :tool_call_failed, else: :tool_call_completed

    [
      legacy_event(event, type, %{
        tool_call_id: payload.tool_id,
        tool_output: payload.content,
        is_error: payload.is_error
      })
    ]
  end

  def bridge_event(
        %Event{kind: :thinking, payload: %Message.Thinking{thinking: thinking}} = event
      )
      when is_binary(thinking) do
    [
      legacy_event(event, :message_streamed, %{
        content: thinking,
        delta: thinking,
        kind: :thinking
      })
    ]
  end

  def bridge_event(%Event{kind: :result, payload: %Message.Result{} = payload} = event) do
    usage = normalize_usage(payload.usage)

    run_completed_data =
      %{stop_reason: payload.stop_reason, duration_ms: payload.duration_ms, token_usage: usage}
      |> maybe_put(:metadata, non_empty_map(payload.metadata))

    [
      legacy_event(event, :token_usage_updated, usage),
      legacy_event(event, :run_completed, run_completed_data)
    ]
  end

  def bridge_event(%Event{kind: :error, payload: %Message.Error{} = payload} = event) do
    error_data = %{
      error_code: payload.kind,
      error_message: payload.message,
      severity: payload.severity
    }

    [
      legacy_event(event, :error_occurred, error_data),
      legacy_event(event, :run_failed, Map.drop(error_data, [:severity]))
    ]
  end

  def bridge_event(
        %Event{kind: :approval_requested, payload: %Control.ApprovalRequest{} = payload} = event
      ) do
    [
      legacy_event(event, :tool_approval_requested, %{
        approval_id: payload.approval_id,
        tool_name: payload.tool_name,
        tool_input: payload.tool_input
      })
    ]
  end

  def bridge_event(
        %Event{kind: :approval_resolved, payload: %Control.ApprovalResolution{} = payload} = event
      ) do
    type = if payload.decision == :allow, do: :tool_approval_granted, else: :tool_approval_denied

    [legacy_event(event, type, %{approval_id: payload.approval_id, reason: payload.reason})]
  end

  def bridge_event(
        %Event{kind: :guardrail_triggered, payload: %Control.GuardrailTrigger{} = payload} = event
      ) do
    [
      legacy_event(event, :policy_violation, %{
        policy: payload.rule,
        kind: payload.direction,
        action: payload.action
      })
    ]
  end

  def bridge_event(%Event{kind: :cost_update, payload: %Control.CostUpdate{} = payload} = event) do
    [
      legacy_event(event, :token_usage_updated, %{
        input_tokens: payload.input_tokens,
        output_tokens: payload.output_tokens,
        cost_usd: payload.cost_usd
      })
    ]
  end

  def bridge_event(%Event{kind: :run_started, payload: %Control.RunLifecycle{} = payload} = event) do
    [legacy_event(event, :run_started, ensure_map(payload.summary))]
  end

  def bridge_event(
        %Event{kind: :run_completed, payload: %Control.RunLifecycle{} = payload} = event
      ) do
    [legacy_event(event, :run_completed, ensure_map(payload.summary))]
  end

  def bridge_event(%Event{}), do: []

  @spec bridge_stream(Enumerable.t()) :: Enumerable.t()
  def bridge_stream(stream) do
    Elixir.Stream.flat_map(stream, &bridge_event/1)
  end

  defp normalize_provider_hint(value) when is_atom(value) do
    atom_name = Atom.to_string(value)

    case Map.fetch(@supported_provider_names, atom_name) do
      {:ok, provider} ->
        {:ok, provider}

      :error ->
        normalize_provider_hint(atom_name)
    end
  end

  defp normalize_provider_hint(value) when is_binary(value) do
    trimmed = String.trim(value)
    downcased = String.downcase(trimmed)

    cond do
      Map.has_key?(@supported_provider_names, downcased) ->
        {:ok, Map.fetch!(@supported_provider_names, downcased)}

      Map.has_key?(@adapter_provider_names, trimmed) ->
        {:ok, Map.fetch!(@adapter_provider_names, trimmed)}

      true ->
        module_name =
          if String.starts_with?(trimmed, "Elixir."),
            do: trimmed,
            else: "Elixir." <> trimmed

        case Map.fetch(@adapter_provider_names, module_name) do
          {:ok, provider} -> {:ok, provider}
          :error -> :error
        end
    end
  end

  defp normalize_provider_hint(_other), do: :error

  defp normalize_messages(messages) when is_list(messages) do
    lines =
      messages
      |> Enum.map(&normalize_message_line/1)
      |> Enum.reject(&is_nil/1)

    case lines do
      [] ->
        {:error,
         config_error(
           "Unsupported input shape. Expected non-empty prompt string or map with `prompt`/`messages`."
         )}

      _ ->
        {:ok, Enum.join(lines, "\n")}
    end
  end

  defp normalize_message_line(%{} = message) do
    role = Map.get(message, :role) || Map.get(message, "role")
    content = Map.get(message, :content) || Map.get(message, "content")
    normalized_content = normalize_content(content)

    if normalized_content == "" do
      nil
    else
      "#{normalize_role(role)}: #{normalized_content}"
    end
  end

  defp normalize_message_line(_other), do: nil

  defp normalize_role(role) when role in [:system, :user, :assistant, :tool],
    do: Atom.to_string(role)

  defp normalize_role(role) when is_binary(role) and role != "", do: String.downcase(role)
  defp normalize_role(_role), do: "user"

  defp normalize_content(nil), do: ""

  defp normalize_content(content) when is_binary(content) do
    if String.trim(content) == "", do: "", else: content
  end

  defp normalize_content(content), do: inspect(content)

  defp ensure_supported_options(opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts)

    with {:ok, normalized_adapter_opts} <- normalize_adapter_opts(adapter_opts) do
      merged = Keyword.merge(Keyword.delete(opts, :adapter_opts), normalized_adapter_opts)

      case first_unsupported_option(merged) do
        nil -> :ok
        {key, message} -> {:error, config_error("#{message} (received: #{inspect(key)})")}
      end
    end
  end

  defp first_unsupported_option(opts) do
    Enum.find(@unsupported_option_messages, fn {key, _message} ->
      value = Keyword.get(opts, key)
      option_set?(value)
    end)
  end

  defp option_set?(nil), do: false
  defp option_set?(false), do: false
  defp option_set?([]), do: false
  defp option_set?(%{} = map), do: map_size(map) > 0
  defp option_set?(_), do: true

  defp build_query_opts(provider, opts) do
    with {:ok, provider_def} <- Provider.resolve(provider),
         {:ok, adapter_opts} <- normalize_adapter_opts(Keyword.get(opts, :adapter_opts)) do
      top_level_query_opts =
        opts
        |> Keyword.drop(@non_query_keys)
        |> normalize_option_keys()

      merged_query_opts =
        top_level_query_opts
        |> Keyword.merge(normalize_option_keys(adapter_opts))
        |> normalize_permission_mode()

      validated =
        merged_query_opts
        |> Keyword.put(:provider, provider_def.name)
        |> Options.validate(provider_def.options_schema)

      case validated do
        {:ok, validated_opts} -> {:ok, Keyword.drop(validated_opts, [:provider])}
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  defp build_session_opts(provider, opts, query_opts) do
    opts
    |> Keyword.take(@session_passthrough_keys)
    |> Keyword.put(:provider, provider)
    |> Keyword.merge(query_opts)
  end

  defp normalize_adapter_opts(nil), do: {:ok, []}

  defp normalize_adapter_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok, opts}
    else
      {:error,
       config_error("`adapter_opts` must be a keyword list or map, got: #{inspect(opts)}")}
    end
  end

  defp normalize_adapter_opts(opts) when is_map(opts) do
    {:ok,
     opts
     |> Enum.map(fn {key, value} -> {key, value} end)
     |> normalize_option_keys()}
  end

  defp normalize_adapter_opts(opts) do
    {:error, config_error("`adapter_opts` must be a keyword list or map, got: #{inspect(opts)}")}
  end

  defp normalize_option_keys(opts) when is_list(opts) do
    Enum.map(opts, fn {key, value} ->
      normalized_key =
        key
        |> normalize_option_key()
        |> then(&Map.get(@option_aliases, &1, &1))

      {normalized_key, value}
    end)
  end

  defp normalize_permission_mode(opts) when is_list(opts) do
    case Keyword.fetch(opts, :permission_mode) do
      {:ok, mode} ->
        Keyword.put(opts, :permission_mode, normalize_permission_mode_value(mode))

      :error ->
        opts
    end
  end

  defp normalize_option_key(key) when is_atom(key), do: key

  defp normalize_option_key(key) when is_binary(key) do
    normalized = String.downcase(String.trim(key))
    Map.get(@string_option_keys, normalized, key)
  end

  defp normalize_option_key(key), do: key

  defp normalize_permission_mode_value(mode) when is_atom(mode) do
    Map.get(@permission_aliases, mode, mode)
  end

  defp normalize_permission_mode_value(mode) when is_binary(mode) do
    normalized = String.downcase(String.trim(mode))

    case Map.get(@string_permission_modes, normalized) do
      nil -> mode
      parsed -> normalize_permission_mode_value(parsed)
    end
  end

  defp normalize_permission_mode_value(mode), do: mode

  defp extract_text(content_blocks) when is_list(content_blocks) do
    content_blocks
    |> Enum.flat_map(fn
      %Content.Text{text: text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join()
  end

  defp extract_text(_other), do: ""

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens:
        as_non_neg_int(Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens")),
      output_tokens:
        as_non_neg_int(Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens"))
    }
  end

  defp normalize_usage(_other), do: %{input_tokens: 0, output_tokens: 0}

  defp as_non_neg_int(value) when is_integer(value) and value >= 0, do: value
  defp as_non_neg_int(value) when is_float(value) and value >= 0, do: trunc(value)

  defp as_non_neg_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> 0
    end
  end

  defp as_non_neg_int(_value), do: 0

  defp legacy_event(%Event{} = event, type, data) when is_atom(type) and is_map(data) do
    %{
      type: type,
      timestamp: event.timestamp,
      session_id: event.session_id,
      run_id: event.run_id,
      data: data,
      provider: normalize_legacy_provider(event.provider)
    }
  end

  defp normalize_legacy_provider(provider) when is_atom(provider), do: provider

  defp normalize_legacy_provider(provider) when is_binary(provider) do
    provider
    |> String.downcase()
    |> then(&Map.get(@legacy_provider_names, &1, :unknown))
  end

  defp normalize_legacy_provider(_provider), do: :unknown

  defp maybe_emit_callback(nil, _mapped_events), do: :ok

  defp maybe_emit_callback(callback, mapped_events) when is_function(callback, 1) do
    Enum.each(mapped_events, callback)
    :ok
  end

  defp maybe_emit_callback(_callback, _mapped_events), do: :ok

  defp legacy_result(result, legacy_events) do
    cost = ensure_map(result.cost)

    %{
      output: %{
        content: result.text,
        stop_reason: result.stop_reason
      },
      token_usage: %{
        input_tokens: as_non_neg_int(cost[:input_tokens]),
        output_tokens: as_non_neg_int(cost[:output_tokens]),
        total_cost_usd: cost[:cost_usd] || 0.0
      },
      events: legacy_events,
      session_id: result.session_id,
      run_id: result.run_id
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp non_empty_map(value) when is_map(value) and map_size(value) > 0, do: value
  defp non_empty_map(_value), do: nil

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_value), do: %{}

  defp config_error(message) do
    Error.new(:config_invalid, :config, message)
  end
end
