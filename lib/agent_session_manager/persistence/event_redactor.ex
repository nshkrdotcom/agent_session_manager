defmodule AgentSessionManager.Persistence.EventRedactor do
  @moduledoc """
  Scans event data for secret patterns and replaces matches with
  redacted placeholders before persistence.

  Redaction is opt-in and controlled via `Config.get(:redaction_enabled)`.

  ## Public API

  - `redact/2` -- redacts an Event struct's `data` and `metadata` maps.
    Returns a result struct with `event`, `redaction_count`, and `fields_redacted`.
  - `redact_map/2` -- redacts an arbitrary map (for user callback wrapping).
    Returns just the redacted map.
  - `default_patterns/0` -- returns the built-in pattern list.

  ## Bypass Vector

  The `event_callback` and telemetry handlers in `SessionManager` receive
  raw event data that has NOT been redacted. To redact data in your
  callback, wrap it with `redact_map/2`:

      event_callback = fn event_data ->
        redacted = EventRedactor.redact_map(event_data)
        MyApp.handle(redacted)
      end

  ## Pattern Format

  Patterns are `{category, Regex.t()}` tuples. The category atom is used
  for categorized replacement mode (`[REDACTED:category]`).
  """

  alias AgentSessionManager.Core.Event

  @type redaction_config :: %{
          optional(:enabled) => boolean(),
          optional(:patterns) =>
            [{atom(), Regex.t()}]
            | [Regex.t() | {atom(), Regex.t()}]
            | :default
            | {:replace, [Regex.t() | {atom(), Regex.t()}]},
          optional(:replacement) => String.t() | :categorized,
          optional(:deep_scan) => boolean(),
          optional(:scan_metadata) => boolean()
        }

  @type redaction_result :: %{
          event: Event.t(),
          redaction_count: non_neg_integer(),
          fields_redacted: [atom()]
        }

  @max_depth 10
  @default_replacement "[REDACTED]"

  @skip_types [
    :session_created,
    :session_started,
    :session_paused,
    :session_resumed,
    :session_completed,
    :session_cancelled,
    :run_started,
    :run_cancelled,
    :run_timeout,
    :token_usage_updated,
    :turn_completed,
    :workspace_snapshot_taken,
    :workspace_diff_computed,
    :error_recovered
  ]

  @redaction_field_map %{
    message_sent: [:content],
    message_received: [:content],
    message_streamed: [:content, :delta],
    tool_call_started: [:tool_input],
    tool_call_completed: [:tool_input, :tool_output],
    tool_call_failed: [:tool_input, :tool_output],
    error_occurred: [:error_message],
    run_failed: [:error_message],
    session_failed: [:error_message],
    policy_violation: [:details]
  }

  @spec default_patterns() :: [{atom(), Regex.t()}]
  def default_patterns do
    [
      # Cloud provider keys
      {:aws_access_key, ~r/AKIA[0-9A-Z]{16}/},
      {:aws_secret_key, ~r/(?i)aws[_-]?secret[_-]?access[_-]?key\s*[:=]\s*\S+/},
      {:gcp_api_key, ~r/AIza[0-9A-Za-z_-]{35}/},

      # AI provider tokens
      {:anthropic_key, ~r/sk-ant-api\S{20,}/},
      {:openai_key, ~r/sk-proj-[a-zA-Z0-9]{20,}/},
      {:openai_legacy_key, ~r/sk-[a-zA-Z0-9]{40,}/},

      # Version control tokens
      {:github_pat, ~r/ghp_[a-zA-Z0-9]{36}/},
      {:github_oauth, ~r/gho_[a-zA-Z0-9]{36}/},
      {:github_app, ~r/ghs_[a-zA-Z0-9]{36}/},
      {:github_refresh, ~r/ghr_[a-zA-Z0-9]{36}/},
      {:github_fine_pat, ~r/github_pat_[a-zA-Z0-9_]{22,}/},
      {:gitlab_token, ~r/glpat-[a-zA-Z0-9_-]{20,}/},

      # Authentication tokens
      {:jwt_token, ~r/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/},
      {:bearer_token, ~r/(?i)(bearer)\s+[a-zA-Z0-9._~+\/=-]{20,}/},

      # Credentials
      {:password, ~r/(?i)(password|passwd|pwd)\s*[:=]\s*\S+/},
      {:api_key_generic, ~r/(?i)(api[_-]?key|apikey)\s*[:=]\s*\S+/},
      {:secret_key, ~r/(?i)(secret[_-]?key|secretkey)\s*[:=]\s*\S+/},
      {:access_token, ~r/(?i)(access[_-]?token|accesstoken)\s*[:=]\s*\S+/},
      {:auth_token, ~r/(?i)(auth[_-]?token|authtoken)\s*[:=]\s*\S+/},

      # Connection strings
      {:connection_string,
       ~r/(?i)(postgres|postgresql|mysql|redis|mongodb|amqp|mssql):\/\/[^\s]+/},

      # Private keys
      {:private_key, ~r/-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----/},

      # Environment variables
      {:env_secret,
       ~r/(?i)(DATABASE_URL|REDIS_URL|SECRET_KEY_BASE|ENCRYPTION_KEY|PRIVATE_KEY)\s*=\s*\S+/}
    ]
  end

  @spec redact(Event.t(), redaction_config()) :: redaction_result()
  def redact(%Event{} = event, config \\ %{}) do
    enabled = Map.get(config, :enabled, false)

    cond do
      not enabled ->
        unchanged_result(event)

      event.type in @skip_types ->
        unchanged_result(event)

      true ->
        patterns = resolve_patterns(config)
        replacement = Map.get(config, :replacement, @default_replacement)
        deep_scan = Map.get(config, :deep_scan, true)
        scan_metadata = Map.get(config, :scan_metadata, false)
        allowed_fields = allowed_field_set(event.type, deep_scan)

        {data, data_count, data_fields} =
          redact_map_tracked(event.data, patterns, replacement, deep_scan, 0, allowed_fields)

        {metadata, metadata_count, metadata_fields} =
          if scan_metadata do
            redact_map_tracked(event.metadata, patterns, replacement, true, 0, :all)
          else
            {event.metadata, 0, []}
          end

        %{
          event: %{event | data: data, metadata: metadata},
          redaction_count: data_count + metadata_count,
          fields_redacted: Enum.uniq(data_fields ++ metadata_fields)
        }
    end
  end

  @spec redact_map(map(), redaction_config()) :: map()
  def redact_map(map, config \\ %{}) when is_map(map) do
    if Map.get(config, :enabled, false) do
      patterns = resolve_patterns(config)
      replacement = Map.get(config, :replacement, @default_replacement)
      {redacted, _, _} = redact_map_tracked(map, patterns, replacement, true, 0, :all)
      redacted
    else
      map
    end
  end

  defp unchanged_result(event) do
    %{event: event, redaction_count: 0, fields_redacted: []}
  end

  defp resolve_patterns(config) do
    case Map.get(config, :patterns, :default) do
      :default ->
        default_patterns()

      {:replace, patterns} when is_list(patterns) ->
        normalize_patterns(patterns)

      patterns when is_list(patterns) ->
        default_patterns() ++ normalize_patterns(patterns)

      _ ->
        default_patterns()
    end
  end

  defp normalize_patterns(patterns) do
    Enum.flat_map(patterns, fn
      {category, %Regex{} = regex} when is_atom(category) ->
        [{category, regex}]

      %Regex{} = regex ->
        [{:custom, regex}]

      _ ->
        []
    end)
  end

  defp redact_map_tracked(map, _patterns, _replacement, _deep_scan, depth, _allowed_fields)
       when depth > @max_depth do
    {map, 0, []}
  end

  defp redact_map_tracked(map, patterns, replacement, deep_scan, depth, allowed_fields)
       when is_map(map) do
    Enum.reduce(map, {map, 0, []}, fn {key, value}, {acc_map, acc_count, acc_fields} ->
      scan_key? = should_scan_key?(key, depth, deep_scan, allowed_fields)

      {new_value, count} =
        redact_value(value, patterns, replacement, deep_scan or scan_key?, depth + 1, scan_key?)

      changed? = new_value != value
      new_map = if changed?, do: Map.put(acc_map, key, new_value), else: acc_map
      new_fields = if changed?, do: track_field(acc_fields, key, depth), else: acc_fields

      {new_map, acc_count + count, new_fields}
    end)
  end

  defp redact_map_tracked(value, _patterns, _replacement, _deep_scan, _depth, _allowed_fields) do
    {value, 0, []}
  end

  defp redact_value(value, patterns, replacement, deep_scan, _depth, force_scan)
       when is_binary(value) do
    if (force_scan or deep_scan) and String.valid?(value) do
      redact_string(value, patterns, replacement)
    else
      {value, 0}
    end
  end

  defp redact_value(value, patterns, replacement, deep_scan, depth, force_scan)
       when is_map(value) do
    if force_scan or deep_scan do
      {map, count, _fields} = redact_map_tracked(value, patterns, replacement, true, depth, :all)
      {map, count}
    else
      {value, 0}
    end
  end

  defp redact_value(value, patterns, replacement, deep_scan, depth, force_scan)
       when is_list(value) do
    if force_scan or deep_scan do
      Enum.reduce(value, {[], 0}, fn item, {acc, count} ->
        {redacted_item, item_count} =
          redact_value(item, patterns, replacement, true, depth + 1, true)

        {[redacted_item | acc], count + item_count}
      end)
      |> then(fn {list, count} -> {Enum.reverse(list), count} end)
    else
      {value, 0}
    end
  end

  defp redact_value(value, _patterns, _replacement, _deep_scan, _depth, _force_scan) do
    {value, 0}
  end

  defp redact_string(value, patterns, replacement) when is_binary(value) do
    Enum.reduce(patterns, {value, 0}, fn {category, pattern}, {acc, count} ->
      case Regex.scan(pattern, acc) do
        [] ->
          {acc, count}

        matches ->
          replaced = apply_replacement(acc, pattern, replacement, category)
          {replaced, count + length(matches)}
      end
    end)
  end

  defp apply_replacement(string, pattern, :categorized, category) do
    Regex.replace(pattern, string, "[REDACTED:#{category}]")
  end

  defp apply_replacement(string, pattern, replacement, _category) when is_binary(replacement) do
    Regex.replace(pattern, string, replacement)
  end

  defp should_scan_key?(_key, _depth, true, _allowed_fields), do: true
  defp should_scan_key?(_key, _depth, false, :all), do: true

  defp should_scan_key?(key, 0, false, allowed_fields) do
    MapSet.member?(allowed_fields, key)
  end

  defp should_scan_key?(_key, _depth, false, _allowed_fields), do: false

  defp allowed_field_set(type, true) do
    fields = Map.get(@redaction_field_map, type, [])
    MapSet.new(fields ++ Enum.map(fields, &Atom.to_string/1))
  end

  defp allowed_field_set(type, false) do
    fields = Map.get(@redaction_field_map, type, [])
    MapSet.new(fields ++ Enum.map(fields, &Atom.to_string/1))
  end

  defp track_field(fields, key, 0) when is_atom(key), do: [key | fields]
  defp track_field(fields, _key, _depth), do: fields
end
